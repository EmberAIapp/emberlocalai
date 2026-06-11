import Foundation

/// Info about one personal model (mirrors `aneforge models --json`).
struct PersonalModelInfo: Identifiable, Codable, Hashable {
    var name: String
    var base: String
    var version: Int
    var steps: Int
    var sessions: Int
    var id: String { name }
}

/// Bridge between the SwiftUI app and the ANEForge engine.
///
/// The engine lives in Python+Rust (`aneforge` CLI). The app drives it as a
/// subprocess — decoupled and robust. A shipped app would bundle a Python
/// runtime; in dev we point at the repo's venv via `EngineConfig`.
struct EngineConfig {
    /// Absolute path to the Python interpreter (the project venv).
    var pythonExecutable: String
    /// Value for PYTHONPATH so `aneforge` is importable (repo `/python` dir).
    var pythonPath: String

    /// Best-effort defaults from the environment, overridable by the app.
    static func resolve() -> EngineConfig {
        let env = ProcessInfo.processInfo.environment
        let python = env["ANEFORGE_PYTHON"] ?? "/usr/bin/python3"
        let pyPath = env["ANEFORGE_PYTHONPATH"] ?? ""
        return EngineConfig(pythonExecutable: python, pythonPath: pyPath)
    }
}

enum EngineError: Error, LocalizedError {
    case nonZeroExit(code: Int32, stderr: String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let code, let err): return "engine exited \(code): \(err)"
        case .decodeFailed(let s): return "could not decode engine output: \(s)"
        }
    }
}

actor Engine {
    let config: EngineConfig

    init(config: EngineConfig = .resolve()) {
        self.config = config
    }

    /// List personal models.
    func models() async throws -> [PersonalModelInfo] {
        let out = try await run(["models", "--json"])
        guard let data = lastJSONLine(out)?.data(using: .utf8) else {
            throw EngineError.decodeFailed(out)
        }
        return try JSONDecoder().decode([PersonalModelInfo].self, from: data)
    }

    /// Create a new personal model.
    func create(name: String, base: String) async throws {
        _ = try await run(["create", name, "--base", base])
    }

    /// One-shot question to the model. Returns the answer text.
    func ask(name: String, prompt: String, maxTokens: Int = 24) async throws -> String {
        let out = try await run(["ask", name, prompt, "--max-tokens", "\(maxTokens)"])
        // The CLI emits the answer behind a "===ANSWER===\t" marker.
        for line in out.split(separator: "\n") {
            if let range = line.range(of: "===ANSWER===\t") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Train the model on a data file, streaming progress lines as they arrive.
    nonisolated func learn(name: String, dataPath: String) -> AsyncThrowingStream<String, Error> {
        streamRun(["learn", name, "--data", dataPath])
    }

    // MARK: - Process plumbing

    nonisolated private func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.pythonExecutable)
        p.arguments = ["-m", "aneforge.cli"] + args
        var env = ProcessInfo.processInfo.environment
        if !config.pythonPath.isEmpty { env["PYTHONPATH"] = config.pythonPath }
        p.environment = env
        return p
    }

    /// Run to completion, returning stdout. Throws on non-zero exit.
    private func run(_ args: [String]) async throws -> String {
        let p = makeProcess(args)
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw EngineError.nonZeroExit(
                code: p.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Run while streaming stdout lines (for live training progress).
    nonisolated private func streamRun(_ args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let p = self.makeProcess(args)
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = outPipe
            let handle = outPipe.fileHandleForReading
            handle.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                if let s = String(data: d, encoding: .utf8) {
                    for line in s.split(separator: "\n") {
                        continuation.yield(String(line))
                    }
                }
            }
            p.terminationHandler = { proc in
                handle.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: EngineError.nonZeroExit(
                        code: proc.terminationStatus, stderr: ""))
                }
            }
            do { try p.run() } catch { continuation.finish(throwing: error) }
        }
    }

    private func lastJSONLine(_ s: String) -> String? {
        s.split(separator: "\n")
            .map(String.init)
            .last(where: { $0.hasPrefix("[") || $0.hasPrefix("{") })
    }
}
