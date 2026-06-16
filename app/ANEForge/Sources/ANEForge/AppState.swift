import SwiftUI

struct ChatMessage: Identifiable, Hashable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
}

/// Central observable state. Owns the Engine and exposes UI-friendly @Published
/// values. All engine work is async; UI updates hop back to the main actor.
@MainActor
final class AppState: ObservableObject {
    @Published var models: [PersonalModelInfo] = []
    @Published var selected: PersonalModelInfo?
    @Published var messages: [ChatMessage] = []
    @Published var isBusy = false
    @Published var trainingLog: [String] = []
    @Published var errorText: String?
    @Published var lastLearned: [String] = []
    @Published var booting = true   // daemon/model still warming up

    private let engine: Engine

    init(engine: Engine = Engine()) {
        self.engine = engine
    }

    /// Launch the daemon + load the model, then refresh. Called once at startup.
    func boot() async {
        booting = true
        await engine.start()
        booting = !(await engine.ready())
        await refresh()
    }

    func refresh() async {
        do { models = try await engine.models() }
        catch { errorText = error.localizedDescription }
    }

    func create(name: String, base: String) async {
        isBusy = true; defer { isBusy = false }
        do {
            try await engine.create(name: name, base: base)
            await refresh()
            selected = models.first { $0.name == name }
        } catch { errorText = error.localizedDescription }
    }

    func teach(dataPath: String) async {
        guard let name = selected?.name else { return }
        isBusy = true; trainingLog = []; defer { isBusy = false }
        do {
            for try await line in engine.learn(name: name, dataPath: dataPath) {
                trainingLog.append(line)
            }
            await refresh()
        } catch { errorText = error.localizedDescription }
    }

    /// Read a user-selected/dropped file IN THE APP (which holds the access grant),
    /// stage it to a temp path the engine subprocess can read, then learn from it.
    /// This sidesteps macOS TCC: the engine never touches the original protected folder.
    func teachFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("ember-\(UUID().uuidString).txt")
            try data.write(to: tmp)
            await teach(dataPath: tmp.path)
        } catch {
            errorText = "Lecture du fichier impossible : \(error.localizedDescription)"
        }
    }

    func deleteModel(_ name: String) async {
        isBusy = true; defer { isBusy = false }
        do {
            try await engine.delete(name: name)
            if selected?.name == name { selected = nil; messages = [] }
            await refresh()
        } catch { errorText = error.localizedDescription }
    }

    func loadSettings(_ name: String) async -> AISettings {
        (try? await engine.getSettings(name: name)) ?? AISettings()
    }

    func saveSettings(_ name: String, persona: String, maxTokens: Int) async {
        do { try await engine.setSettings(name: name, persona: persona, maxTokens: maxTokens) }
        catch { errorText = error.localizedDescription }
    }

    func send(_ prompt: String) async {
        guard let name = selected?.name, !prompt.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: prompt))
        isBusy = true; defer { isBusy = false }
        do {
            let reply = try await engine.chat(name: name, prompt: prompt)
            messages.append(ChatMessage(role: .assistant, text: reply.answer))
            lastLearned = reply.learned
        } catch {
            messages.append(ChatMessage(role: .assistant, text: "⚠️ \(error.localizedDescription)"))
        }
    }
}
