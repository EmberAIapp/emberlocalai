import SwiftUI
import PDFKit

struct ChatMessage: Identifiable, Hashable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
}

/// Which primary screen is showing in the main content area.
enum MainView { case home, ingest, memory, settings }

/// Central observable state. Owns the Engine and exposes UI-friendly @Published
/// values. All engine work is async; UI updates hop back to the main actor.
@MainActor
final class AppState: ObservableObject {
    @Published var models: [PersonalModelInfo] = []
    @Published var selected: PersonalModelInfo?
    @Published var messages: [ChatMessage] = []
    @Published var facts: [Fact] = []
    @Published var isBusy = false          // generating a reply
    @Published var isLearning = false      // ingesting / training
    @Published var talking = false         // briefly true right after a reply lands
    @Published var trainingLog: [String] = []
    @Published var errorText: String?
    @Published var lastLearned: [String] = []
    @Published var booting = true          // daemon/model still warming up

    // Navigation / overlays
    @Published var view: MainView = .home
    @Published var isHer = false
    @Published var onboardStep = 0          // 0 = closed, 1…3 = onboarding pages
    @Published var switcherOpen = false

    // Réglages (UI state — persona + length are persisted to the engine on save)
    @Published var selectedModelIndex = 1
    @Published var personaSel = "Calme"
    @Published var permissions = DesignData.defaultPermissions

    // Le fil — local agent orchestration surface (roadmap; the UI is fully interactive)
    enum Gate { case none, pending, granted, denied }
    @Published var agentRunning = false
    @Published var agentPaused = false
    @Published var agentExpanded = false
    @Published var agentStep = 1            // index into DesignData.agentSteps
    @Published var agentGate: Gate = .none
    private var agentTicker: Task<Void, Never>?

    var onboardOpen: Bool { onboardStep > 0 }

    private let engine: Engine

    init(engine: Engine = Engine()) {
        self.engine = engine
    }

    /// The orb's living state, derived from what Ember is actually doing.
    var orbMode: OrbMode {
        if isLearning { return .apprend }
        if isBusy { return .reflexion }
        if talking { return .parle }
        return .repos
    }

    /// Launch the daemon + load the model, then refresh. Called once at startup.
    func boot() async {
        booting = true
        await engine.start()
        booting = !(await engine.ready())
        await refresh()
        // First run (no IA yet) → show the onboarding.
        if models.isEmpty { onboardStep = 1 }
        else if selected == nil { select(models.first) }
        startAgentTicker()
    }

    func refresh() async {
        do { models = try await engine.models() }
        catch { errorText = error.localizedDescription }
    }

    /// Switch the active IA: load its conversation-agnostic memory and reset the view.
    func select(_ model: PersonalModelInfo?) {
        selected = model
        messages = []
        facts = []
        switcherOpen = false
        if let m = model { Task { await loadFacts(m.name) } }
    }

    func create(name: String, base: String) async {
        isBusy = true; defer { isBusy = false }
        do {
            try await engine.create(name: name, base: base)
            await refresh()
            select(models.first { $0.name == name })
        } catch { errorText = error.localizedDescription }
    }

    func teach(dataPath: String) async {
        guard let name = selected?.name else { return }
        isLearning = true; trainingLog = []; defer { isLearning = false }
        do {
            for try await line in engine.learn(name: name, dataPath: dataPath) {
                trainingLog.append(line)
            }
            await refresh()
            await loadFacts(name)
        } catch { errorText = error.localizedDescription }
    }

    // MARK: - Memory

    func loadFacts(_ name: String) async {
        facts = (try? await engine.memory(name: name)) ?? []
    }

    func forget(_ fact: Fact) async {
        guard let name = selected?.name else { return }
        try? await engine.forget(name: name, id: fact.id)
        await loadFacts(name)
    }

    func forgetAll() async {
        guard let name = selected?.name else { return }
        try? await engine.forgetAll(name: name)
        facts = []
    }

    func replayOnboard() { onboardStep = 1 }
    func skipOnboard() { onboardStep = 0 }
    func onboardNext() {
        if onboardStep >= 3 { onboardStep = 0; view = .home }
        else { onboardStep += 1 }
    }

    // MARK: - Navigation

    func go(_ v: MainView) { view = v; switcherOpen = false }
    func enterHer() { isHer = true; switcherOpen = false; if !agentRunning { startAgent() } }
    func exitHer() { isHer = false }

    // MARK: - Le fil (agent orchestration)

    /// Advance the demo orchestration: one step every 2.2 s unless paused or waiting at a gate.
    private func startAgentTicker() {
        agentTicker?.cancel()
        agentTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                await MainActor.run { self?.tickAgent() }
            }
        }
    }

    private func tickAgent() {
        let steps = DesignData.agentSteps
        guard agentRunning, !agentPaused, agentStep < steps.count else { return }
        if steps[agentStep].gate && agentGate == .pending { return }   // wait for the user
        agentStep += 1
        if agentStep < steps.count, steps[agentStep].gate,
           agentGate != .granted, agentGate != .denied {
            agentGate = .pending
        }
    }

    func resolveGate(_ ok: Bool) {
        agentGate = ok ? .granted : .denied
        agentStep = min(DesignData.agentSteps.count, agentStep + 1)
        agentPaused = false
    }

    func toggleAgentPause() { agentPaused.toggle() }
    func toggleAgentExpand() { agentExpanded.toggle() }
    func stopAgent() { agentRunning = false; agentExpanded = false }
    func startAgent() { agentRunning = true; agentPaused = false; agentExpanded = false; agentStep = 1; agentGate = .none }

    // Derived state used by Le fil + Mode Her to render the orchestration.
    enum StepState { case done, doing, gate, pending, denied }

    func agentStepState(_ i: Int) -> StepState {
        let steps = DesignData.agentSteps
        let st = steps[i]
        if st.gate && agentGate == .denied { return .denied }
        if i < agentStep { return .done }
        if i == agentStep {
            if st.gate && agentGate == .pending { return .gate }
            if agentStep >= steps.count { return .pending }
            return .doing
        }
        return .pending
    }

    var agentFinished: Bool { agentStep >= DesignData.agentSteps.count }
    var agentAwaiting: Bool {
        let steps = DesignData.agentSteps
        return agentStep < steps.count && steps[agentStep].gate && agentGate == .pending
    }
    var agentWorking: Bool { agentRunning && !agentPaused && !agentAwaiting && !agentFinished }
    var agentProgress: Double {
        Double(min(DesignData.agentSteps.count, agentStep)) / Double(DesignData.agentSteps.count)
    }
    var agentBarText: String {
        if agentPaused { return "En pause — reprends quand tu veux" }
        if agentAwaiting { return "En attente de ton feu vert" }
        if agentFinished { return "Terminé · ton dossier est prêt" }
        let steps = DesignData.agentSteps
        return agentStep < steps.count ? steps[agentStep].text + "…" : ""
    }

    /// Read a user-selected/dropped file IN THE APP (which holds the access grant),
    /// stage it to a temp path the engine subprocess can read, then learn from it.
    /// This sidesteps macOS TCC: the engine never touches the original protected folder.
    /// §4.A — learn from a dropped file by extracting its facts into memory (reliable recall),
    /// not by fine-tuning weights. Reads .txt/.md as UTF-8 and .pdf via PDFKit.
    func teachFile(_ url: URL) async {
        guard let name = selected?.name else {
            errorText = "Choisis (ou crée) d'abord une IA."; return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        isLearning = true; trainingLog = []; defer { isLearning = false }
        do {
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                text = PDFDocument(url: url)?.string ?? ""
            } else {
                let data = try Data(contentsOf: url)
                text = String(data: data, encoding: .utf8)
                    ?? String(decoding: data, as: UTF8.self)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorText = "Fichier vide ou illisible : \(url.lastPathComponent)"; return
            }
            trainingLog.append("Lecture de \(url.lastPathComponent)…")
            let learned = try await engine.ingest(name: name, text: text)
            trainingLog.append("✦ \(learned) fait(s) appris depuis \(url.lastPathComponent)")
            await loadFacts(name)
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

    func renameModel(_ old: String, to newName: String) async {
        let new = newName.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        let wasSelected = selected?.name == old
        isBusy = true; defer { isBusy = false }
        do {
            try await engine.rename(name: old, to: new)
            await refresh()
            if wasSelected { selected = models.first { $0.name == new } }
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
