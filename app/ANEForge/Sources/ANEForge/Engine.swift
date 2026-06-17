import Foundation

/// Info about one personal model (mirrors the daemon's /models).
struct PersonalModelInfo: Identifiable, Codable, Hashable {
    var name: String
    var base: String
    var version: Int
    var steps: Int
    var id: String { name }
}

struct ChatReply: Codable {
    var answer: String
    var learned: [String]
    var source: String
}

/// One remembered fact (mirrors the daemon's /memory rows).
struct Fact: Identifiable, Codable, Hashable {
    var id: Int
    var kind: String
    var text: String
    var source: String
}

struct AISettings: Codable {
    var persona: String = ""
    var maxTokens: Int = 220
    enum CodingKeys: String, CodingKey { case persona; case maxTokens = "max_tokens" }
}

struct EngineConfig {
    var pythonExecutable: String
    var pythonPath: String
    static func resolve() -> EngineConfig {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return EngineConfig(
            pythonExecutable: env["ANEFORGE_PYTHON"] ?? "\(home)/.ember-engine/venv/bin/python",
            pythonPath: env["ANEFORGE_PYTHONPATH"] ?? "\(home)/.ember-engine")
    }
}

enum EngineError: Error, LocalizedError {
    case http(String)
    var errorDescription: String? { if case .http(let s) = self { return s }; return nil }
}

/// Talks to the persistent Ember daemon over localhost (chat is instant — the MLX
/// model stays loaded). Training (`learn`) still streams from a CLI subprocess.
actor Engine {
    let config: EngineConfig
    let port = 8765
    private var daemon: Process?
    private var base: String { "http://127.0.0.1:\(port)" }

    init(config: EngineConfig = .resolve()) { self.config = config }

    // MARK: - Daemon lifecycle

    /// Launch the daemon if it isn't already serving, and wait until the model is ready.
    func start() async {
        if await healthReady() { return }
        let p = rawProcess(["-m", "aneforge.ember_daemon", "--port", "\(port)"])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); daemon = p } catch { return }
        // Poll /health until the model is loaded (model download can take a while first time).
        for _ in 0..<150 {
            if await healthReady() { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func ready() async -> Bool { await healthReady() }

    private func healthReady() async -> Bool {
        guard let d = try? await get("/health"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return false }
        return (j["ready"] as? Bool) ?? false
    }

    // MARK: - API

    func models() async throws -> [PersonalModelInfo] {
        try JSONDecoder().decode([PersonalModelInfo].self, from: try await get("/models"))
    }

    func create(name: String, base: String) async throws {
        _ = try await post("/create", ["name": name, "base": base])
    }

    func delete(name: String) async throws {
        _ = try await post("/delete", ["name": name])
    }

    func rename(name: String, to newName: String) async throws {
        _ = try await post("/rename", ["name": name, "new": newName])
    }

    /// Learn from a file's text by extracting facts into memory. Returns the number learned.
    func ingest(name: String, text: String) async throws -> Int {
        struct R: Decodable { let learned: Int }
        let data = try await post("/ingest", ["name": name, "text": text])
        return (try? JSONDecoder().decode(R.self, from: data))?.learned ?? 0
    }

    /// Token-by-token reply stream (§5.4). Yields text deltas as the model generates.
    nonisolated func chatStream(name: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let url = URL(string: "http://127.0.0.1:\(port)/chat_stream")!
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "prompt": prompt])
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    var buf = [UInt8]()
                    for try await b in bytes {
                        buf.append(b)
                        // emit as soon as the accumulated bytes form valid UTF-8 (handles multibyte)
                        if let s = String(bytes: buf, encoding: .utf8) {
                            continuation.yield(s)
                            buf.removeAll(keepingCapacity: true)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Mode Her — stream the agent's events (plan, tool, observation, gate, done) as NDJSON.
    nonisolated func agentStream(name: String, task: String, trust: Bool = false) -> AsyncThrowingStream<AgentEvent, Error> {
        let url = URL(string: "http://127.0.0.1:\(port)/agent_stream")!
        return AsyncThrowingStream { continuation in
            let job = Task {
                do {
                    var req = URLRequest(url: url); req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "task": task, "trust": trust])
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        guard let d = line.data(using: .utf8),
                              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let type = o["type"] as? String else { continue }
                        var e = AgentEvent(type: type)
                        e.text = (o["text"] as? String) ?? (o["summary"] as? String) ?? ""
                        e.tool = (o["tool"] as? String) ?? (o["name"] as? String) ?? ""
                        e.scope = (o["scope"] as? String) ?? ""
                        e.denied = (o["denied"] as? Bool) ?? false
                        if type == "session" { e.detail = (o["id"] as? String) ?? "" }
                        if let args = o["args"] as? [String: Any] {
                            e.detail = (args["filename"] as? String) ?? (args["query"] as? String)
                                     ?? (args["path"] as? String) ?? (args["name"] as? String)
                                     ?? (args["url"] as? String) ?? (args["pattern"] as? String)
                                     ?? (args["title"] as? String) ?? (args["text"] as? String)
                                     ?? (args["action"] as? String) ?? (args["subject"] as? String)
                                     ?? (args["src"] as? String) ?? e.detail
                        }
                        continuation.yield(e)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in job.cancel() }
        }
    }

    /// Resume a paused agent after a permission gate (allow / deny).
    nonisolated func agentResume(session: String, allow: Bool, remember: Bool = false) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/agent_resume") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["session": session, "allow": allow, "remember": remember])
        _ = try? await URLSession.shared.data(for: req)
    }

    func chat(name: String, prompt: String) async throws -> ChatReply {
        try JSONDecoder().decode(ChatReply.self, from: try await post("/chat", ["name": name, "prompt": prompt]))
    }

    /// Mode Her router (§4.E): "chat" (local conversation) or "task" (DeepSeek work-agent).
    /// Conversation-first — defaults to chat on any error.
    func route(name: String, message: String) async -> String {
        guard let d = try? await post("/route", ["name": name, "message": message]),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let mode = o["mode"] as? String else { return "chat" }
        return mode
    }

    /// Ember's local neural voice (Kokoro). Returns WAV bytes, or nil so the caller can
    /// fall back to the OS voice (e.g. unsupported language or stack unavailable).
    func tts(text: String, lang: String) async -> Data? {
        guard let url = URL(string: base + "/tts") else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "lang": lang])
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              let h = resp as? HTTPURLResponse, h.statusCode == 200, !d.isEmpty else { return nil }
        return d
    }

    func reset(name: String) async { _ = try? await post("/reset", ["name": name]) }

    /// Current engine config from /health: loaded model id, model currently (re)loading, key set.
    func config() async -> (model: String, loading: String?, hasKey: Bool) {
        guard let d = try? await get("/health"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return ("", nil, false) }
        return ((j["model"] as? String) ?? "", j["loading"] as? String, (j["has_key"] as? Bool) ?? false)
    }

    /// Change the local model directly (Réglages). Reloads it server-side (downloads if needed).
    func setModel(_ id: String) async { _ = try? await post("/set_model", ["model": id]) }

    /// Set/clear the DeepSeek API key (work-agent). Never hard-coded.
    func setKey(_ key: String) async { _ = try? await post("/set_key", ["key": key]) }

    func memory(name: String) async throws -> [Fact] {
        try JSONDecoder().decode([Fact].self, from: try await get("/memory?name=\(name)"))
    }

    /// The personal profile Ember refreshes while idle (real, generated from your facts).
    func profile(name: String) async -> String {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let d = try? await get("/profile?name=\(q)"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        return (j["profile"] as? String) ?? ""
    }

    func forget(name: String, id: Int) async throws {
        _ = try await post("/forget", ["name": name, "id": id])
    }

    func forgetAll(name: String) async throws {
        _ = try await post("/forget", ["name": name, "all": true])
    }

    func getSettings(name: String) async throws -> AISettings {
        try JSONDecoder().decode(AISettings.self, from: try await get("/settings?name=\(name)"))
    }

    func setSettings(name: String, persona: String, maxTokens: Int) async throws {
        _ = try await post("/settings", ["name": name, "persona": persona, "max_tokens": maxTokens])
    }

    /// Train on a data file — still a streaming CLI subprocess (Rust engine).
    nonisolated func learn(name: String, dataPath: String) -> AsyncThrowingStream<String, Error> {
        streamRun(["-m", "aneforge.cli", "learn", name, "--data", dataPath])
    }

    // MARK: - HTTP

    private func get(_ path: String) async throws -> Data {
        let (d, _) = try await URLSession.shared.data(from: URL(string: base + path)!)
        return d
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            throw EngineError.http(msg ?? "erreur \(h.statusCode)")
        }
        return d
    }

    // MARK: - Process plumbing (daemon launch + training stream)

    nonisolated private func rawProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.pythonExecutable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = config.pythonPath
        if env["HOME"] == nil { env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        p.environment = env
        return p
    }

    nonisolated private func streamRun(_ args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let p = self.rawProcess(args)
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = outPipe
            let handle = outPipe.fileHandleForReading
            handle.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                if let s = String(data: d, encoding: .utf8) {
                    for line in s.split(separator: "\n") { continuation.yield(String(line)) }
                }
            }
            p.terminationHandler = { _ in
                handle.readabilityHandler = nil
                continuation.finish()
            }
            do { try p.run() } catch { continuation.finish(throwing: error) }
        }
    }
}
