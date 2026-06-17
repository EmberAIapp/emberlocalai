import SwiftUI
import PDFKit

struct ChatMessage: Identifiable, Hashable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
}

/// One event from the real agent stream (Mode Her).
struct AgentEvent: Identifiable, Hashable {
    let id = UUID()
    let type: String            // plan | tool | observation | gate | message | done | error | session
    var text: String = ""
    var tool: String = ""
    var scope: String = ""
    var detail: String = ""     // filename/query/path for tools, or the session id
    var denied: Bool = false
}

/// One turn of the Mode Her conversation (the "flux conversation", §4.E).
struct HerTurn: Identifiable, Equatable {
    enum Role { case user, ember }
    let id = UUID()
    let role: Role
    var text: String
    var working: Bool = false   // an "Ember travaille…" turn whose detail is the work stream
}

/// A request for Ember to speak a line aloud (consumed by the view → SpeechController).
struct SpeakRequest: Equatable { let id = UUID(); var text: String; var lang: String }

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

    // Mode Her — the REAL agent (DeepSeek brain + local tools). Drives the live panel.
    @Published var agentEvents: [AgentEvent] = []
    @Published var agentBusy = false
    @Published var agentPendingGate: AgentEvent?       // non-nil while waiting on a permission
    private var agentSession: String?
    private var agentTask: Task<Void, Never>?

    // Mode Her — TWO FLOWS (§4.E): a conversation (local chat, Ember talks back) + a work
    // stream (the agent above). Ember chats by default and auto-switches to work when she
    // detects a real task. `herSpeak` is set whenever a line should be spoken aloud.
    @Published var herConversation: [HerTurn] = []
    @Published var herListening = false                // mic is open (orb → écoute)
    @Published var herSpeaking = false                 // a reply is playing (orb → parle)
    @Published var herSpeak: SpeakRequest?             // view observes → plays via SpeechController
    @Published var herMode = "chat"                    // last route decision (UI hint)

    /// The language Ember should speak — follows the system, like the rest of the UI.
    var herLang: String { Locale.current.language.languageCode?.identifier ?? "fr" }

    var onboardOpen: Bool { onboardStep > 0 }

    private let engine: Engine

    init(engine: Engine = Engine()) {
        self.engine = engine
    }

    /// The orb's living state, derived from what Ember is actually doing.
    var orbMode: OrbMode {
        if isLearning { return .apprend }
        if herListening { return .ecoute }   // Mode Her mic open — §3 "elle écoute"
        if agentBusy { return .reflexion }   // Mode Her agent working — §3 "ça calcule"
        if isBusy { return .reflexion }
        if herSpeaking || talking { return .parle }
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
    func enterHer() {
        isHer = true; switcherOpen = false
        agentEvents = []; agentPendingGate = nil; agentBusy = false
        herConversation = []; herListening = false; herSpeaking = false; herSpeak = nil
        if !agentRunning { startAgent() }
    }

    // MARK: - Mode Her conversation (§4.E): chat by default, auto-route to the work agent

    /// One spoken or typed line from the user. Routes to conversation (local, streamed) or
    /// work (the DeepSeek agent), keeping a single visible timeline. Ember speaks her reply.
    func herSend(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let name = selected?.name, !agentBusy else { return }
        herConversation.append(HerTurn(role: .user, text: text))
        Task {
            let mode = await engine.route(name: name, message: text)
            herMode = mode
            if mode == "task" {
                let ack = "D'accord, je m'en occupe."
                herConversation.append(HerTurn(role: .ember, text: ack, working: true))
                herSpeak = SpeakRequest(text: ack, lang: herLang)
                runAgentTask(text)                       // fills agentEvents; speaks summary on done
            } else {
                let idx = herConversation.count
                herConversation.append(HerTurn(role: .ember, text: ""))
                isBusy = true; defer { isBusy = false; talking = false }
                var acc = ""
                do {
                    for try await delta in engine.chatStream(name: name, prompt: text) {
                        if acc.isEmpty { isBusy = false; talking = true }
                        acc += delta
                        if idx < herConversation.count { herConversation[idx].text = acc }
                    }
                } catch { acc = "" }
                if acc.isEmpty, idx < herConversation.count { herConversation[idx].text = "…" }
                herSpeak = SpeakRequest(text: acc.isEmpty ? "" : acc, lang: herLang)
            }
        }
    }

    /// Fetch Ember's neural voice (Kokoro wav) for a line — nil → caller uses the OS voice.
    func ttsData(_ text: String, _ lang: String) async -> Data? {
        await engine.tts(text: text, lang: lang)
    }

    // MARK: - Real agent (Mode Her): DeepSeek brain + local tools, live stream + permission gates
    func runAgentTask(_ task: String) {
        guard let name = selected?.name else { errorText = "Choisis (ou crée) d'abord une IA."; return }
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !agentBusy else { return }
        agentEvents = []; agentPendingGate = nil; agentSession = nil; agentBusy = true
        agentTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await e in engine.agentStream(name: name, task: t) {
                    if e.type == "session" { self.agentSession = e.detail; continue }
                    if e.type == "gate" { self.agentPendingGate = e }
                    self.agentEvents.append(e)
                    // Work summary flows back into the conversation timeline + is spoken aloud.
                    if (e.type == "done" || e.type == "message"), !e.text.isEmpty {
                        self.herConversation.append(HerTurn(role: .ember, text: e.text))
                        self.herSpeak = SpeakRequest(text: e.text, lang: self.herLang)
                    }
                    if e.type == "done" || e.type == "error" { break }
                }
            } catch {
                self.agentEvents.append(AgentEvent(type: "error", text: error.localizedDescription))
            }
            self.agentPendingGate = nil
            self.agentBusy = false
        }
    }

    func resolveAgentGate(_ allow: Bool) {
        guard let s = agentSession else { return }
        agentPendingGate = nil
        Task { await engine.agentResume(session: s, allow: allow) }
    }

    func stopAgentTask() { agentTask?.cancel(); agentBusy = false; agentPendingGate = nil }
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
        let idx = messages.count
        messages.append(ChatMessage(role: .assistant, text: ""))   // fill token-by-token
        isBusy = true                       // reflexion while waiting for the first token
        defer { isBusy = false; talking = false }
        var acc = ""
        do {
            for try await delta in engine.chatStream(name: name, prompt: prompt) {
                if acc.isEmpty { isBusy = false; talking = true }   // first token → parle (ondulations §3)
                acc += delta
                if idx < messages.count { messages[idx].text = acc }
            }
            if acc.isEmpty, idx < messages.count { messages[idx].text = "…" }
        } catch {
            if idx < messages.count { messages[idx].text = "⚠️ \(error.localizedDescription)" }
        }
    }
}
