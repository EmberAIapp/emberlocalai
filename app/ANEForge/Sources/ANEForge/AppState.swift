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

    private let engine: Engine

    init(engine: Engine = Engine()) {
        self.engine = engine
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

    func send(_ prompt: String) async {
        guard let name = selected?.name, !prompt.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: prompt))
        isBusy = true; defer { isBusy = false }
        do {
            let answer = try await engine.ask(name: name, prompt: prompt, maxTokens: 24)
            messages.append(ChatMessage(role: .assistant, text: answer))
        } catch {
            messages.append(ChatMessage(role: .assistant, text: "⚠️ \(error.localizedDescription)"))
        }
    }
}
