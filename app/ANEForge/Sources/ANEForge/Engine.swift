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

    func chat(name: String, prompt: String) async throws -> ChatReply {
        try JSONDecoder().decode(ChatReply.self, from: try await post("/chat", ["name": name, "prompt": prompt]))
    }

    func reset(name: String) async { _ = try? await post("/reset", ["name": name]) }

    func memory(name: String) async throws -> [Fact] {
        try JSONDecoder().decode([Fact].self, from: try await get("/memory?name=\(name)"))
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
