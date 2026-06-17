import SwiftUI
import PDFKit
import AppKit

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
    @Published var lastLearned: [Fact] = []         // facts learned by the most recent ingestion
    @Published var connectedFolders: [String] = []  // local folder connectors (persisted, per-IA)
    @Published var errorText: String? { didSet { if errorText != nil { flashOrbError() } } }
    @Published var orbError = false        // brief alert pulse on the orb (§3 « Erreur »)
    @Published var booting = true          // daemon/model still warming up

    private func flashOrbError() {
        orbError = true
        Task { @MainActor in try? await Task.sleep(nanoseconds: 1_400_000_000); orbError = false }
    }

    // Navigation / overlays
    @Published var view: MainView = .home
    @Published var isHer = false
    @Published var onboardStep = 0          // 0 = closed, 1…3 = onboarding pages
    @Published var switcherOpen = false

    // Réglages (UI state — persona + length are persisted to the engine on save)
    @Published var selectedModelIndex = 1
    @Published var personaSel = "Calme"
    @Published var permissions = AppState.loadPermissions()

    static func loadPermissions() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: "ember.permissions") as? [String: Bool])
            ?? DesignData.defaultPermissions
    }
    /// Set a permission and persist it (revocable + sticky). OFF → the agent hard-denies that scope.
    func setPermission(_ key: String, _ on: Bool) {
        permissions[key] = on
        UserDefaults.standard.set(permissions, forKey: "ember.permissions")
    }
    /// Scopes the user turned OFF → sent to the agent as a hard blocklist.
    var blockedScopes: [String] { permissions.filter { !$0.value }.map(\.key) }

    // Engine config (real): which local model is loaded / (re)loading, and whether the API key is set.
    @Published var currentModelId = ""
    @Published var modelLoading: String? = nil
    @Published var hasKey = false

    func refreshConfig() async {
        let c = await engine.config()
        currentModelId = c.model; modelLoading = c.loading; hasKey = c.hasKey
    }
    /// Change the local model directly (Réglages) — reloads server-side, polled until ready.
    func setModel(_ id: String) {
        guard id != currentModelId, modelLoading == nil else { return }
        modelLoading = id
        Task {
            await engine.setModel(id)
            for _ in 0..<240 {                      // up to ~6 min (first download can be long)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let c = await engine.config()
                currentModelId = c.model; modelLoading = c.loading
                if c.loading == nil { break }
            }
            modelLoading = nil
        }
    }
    func setKey(_ key: String) {
        Task { await engine.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines)); await refreshConfig() }
    }

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
    @Published var voiceSession = false                // continuous "voice mode" (mains-libres en boucle)
    @Published var lastSpoken = ""                      // Ember's last spoken line (for echo rejection)
    @Published var trustMode = false                   // "mode confiance": auto-allow non-Tier-3 actions
    @Published var fullDuplexWanted = false            // opt-in to talk-over (AEC) vs reliable turn-based

    /// True if a transcript is most likely Ember's OWN voice picked up by the mic (no AEC) —
    /// i.e. it overlaps heavily with what she just said. Prevents the self-talk feedback loop.
    func isEcho(_ t: String) -> Bool {
        let spoken = lastSpoken.lowercased()
        guard spoken.count > 8, herSpeaking || (lastSpoken.count > 8) else { return false }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 })
        }
        let tw = words(t)
        if tw.isEmpty { return true }                  // empty / pure noise → not a real message
        let sw = words(spoken)
        let overlap = Double(tw.filter { sw.contains($0) }.count) / Double(tw.count)
        return overlap >= 0.5
    }

    /// Spoken phrases that END the continuous voice session (said between turns).
    private static let stopPhrases: Set<String> = [
        "stop", "arrête", "arrete", "arrête-toi", "arrete toi", "tais-toi", "tais toi",
        "c'est bon", "ça suffit", "ca suffit", "au revoir", "stop ember", "arrête ember"
    ]
    func isStopPhrase(_ s: String) -> Bool {
        let k = s.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if Self.stopPhrases.contains(k) { return true }
        return k == "stop" || k.hasPrefix("stop ") || k == "arrête" || k == "arrete"
    }

    /// The language Ember should speak — follows the system, like the rest of the UI.
    var herLang: String { Locale.current.language.languageCode?.identifier ?? "fr" }

    var onboardOpen: Bool { onboardStep > 0 }

    private let engine: Engine

    init(engine: Engine = Engine()) {
        self.engine = engine
    }

    /// The orb's living state, derived from what Ember is actually doing.
    var orbMode: OrbMode {
        if orbError { return .erreur }       // brève pulsation d'alerte (§3), puis retour au calme
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
        await refreshConfig()                    // real model/key status for Réglages
        // (the old illustrative "Le fil" café demo bar is no longer started — réel only)
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

    @Published var profileText = ""        // real auto-profile (built while idle)
    @Published var factQuery = ""          // Mémoire search box text
    @Published var searchResults: [Fact] = []
    @Published var searching = false

    /// Facts to show in Mémoire: the search results when a query is active, else everything.
    var visibleFacts: [Fact] {
        factQuery.trimmingCharacters(in: .whitespaces).isEmpty ? facts : searchResults
    }

    func loadFacts(_ name: String) async {
        facts = (try? await engine.memory(name: name)) ?? []
        profileText = await engine.profile(name: name)
    }

    /// Add a fact the user typed by hand, then refresh (the new fact must show immediately).
    func addFact(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let name = selected?.name else { return }
        try? await engine.addFact(name: name, text: t)
        await loadFacts(name)
        if !factQuery.trimmingCharacters(in: .whitespaces).isEmpty { await runSearch(factQuery) }
    }

    /// Debounced live search (called from the view as the query changes).
    func runSearch(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let name = selected?.name else { return }
        if q.isEmpty { searchResults = []; searching = false; return }
        searching = true
        searchResults = (try? await engine.searchFacts(name: name, query: q)) ?? []
        searching = false
    }

    func forget(_ fact: Fact) async {
        guard let name = selected?.name else { return }
        try? await engine.forget(name: name, id: fact.id)
        await loadFacts(name)
        if !factQuery.trimmingCharacters(in: .whitespaces).isEmpty { await runSearch(factQuery) }
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
        herConversation = []; herListening = false; herSpeaking = false; herSpeak = nil; voiceSession = false
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
                for try await e in engine.agentStream(name: name, task: t, trust: trustMode, blocked: blockedScopes) {
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

    func resolveAgentGate(_ allow: Bool, remember: Bool = false) {
        guard let s = agentSession else { return }
        agentPendingGate = nil
        Task { await engine.agentResume(session: s, allow: allow, remember: remember) }
    }

    /// Interpret a spoken reply to a pending permission gate (mains libres). nil = not a yes/no.
    func voiceGateAnswer(_ s: String) -> Bool? {
        let k = s.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let yes = ["oui", "ouais", "ok", "okay", "d'accord", "daccord", "vas-y", "vas y", "vasy",
                   "autorise", "autoriser", "autorisé", "go", "yes", "bien sûr", "bien sur", "carrément", "carrement"]
        let no = ["non", "refuse", "refuser", "refusé", "annule", "annuler", "pas maintenant", "surtout pas", "no"]
        if yes.contains(k) || yes.contains(where: { k.hasPrefix($0 + " ") }) { return true }
        if no.contains(k) || no.contains(where: { k.hasPrefix($0 + " ") }) { return false }
        return nil
    }

    func stopAgentTask() { agentTask?.cancel(); agentBusy = false; agentPendingGate = nil }
    func exitHer() { isHer = false; voiceSession = false }

    /// Read a user-selected/dropped file IN THE APP (which holds the access grant),
    /// stage it to a temp path the engine subprocess can read, then learn from it.
    /// This sidesteps macOS TCC: the engine never touches the original protected folder.
    /// §4.A — learn from a dropped file by extracting its facts into memory (reliable recall),
    /// not by fine-tuning weights. Reads .txt/.md as UTF-8 and .pdf via PDFKit.
    nonisolated static let supportedExt: Set<String> = ["txt", "md", "markdown", "text", "pdf", "rtf", "csv"]
    nonisolated static let fileCap = 80   // bound a folder/full scan so a huge tree can't run for hours

    func teachFile(_ url: URL) async { await teachPaths([url]) }

    /// Learn from any mix of dropped/selected files AND folders (folders are walked for
    /// supported types). 100% local: each file's text → the local model's fact extractor.
    /// Surfaces exactly what was learned (`lastLearned`) so it's tangible.
    private var learnTask: Task<Void, Never>?

    /// Start a (cancelable) learning run over files/folders. `full` raises the cap for a
    /// whole-Mac scan. Callers use this instead of awaiting teachPaths so it can be stopped.
    func learn(_ urls: [URL], full: Bool = false) {
        learnTask?.cancel()
        learnTask = Task { await self.teachPaths(urls, full: full) }
    }

    /// Stop the running scan — keeps everything learned so far (no rollback).
    func cancelLearning() { learnTask?.cancel() }

    func teachPaths(_ urls: [URL], full: Bool = false) async {
        guard let name = selected?.name else {
            errorText = "Choisis (ou crée) d'abord une IA."; return
        }
        guard !isLearning, !urls.isEmpty else { return }
        isLearning = true; trainingLog = []; lastLearned = []; defer { isLearning = false }

        // Hold the security scope of each picked top-level URL while we read its children.
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        let before = Set(((try? await engine.memory(name: name)) ?? []).map(\.id))
        let cap = full ? 250 : Self.fileCap
        let all = Self.expandToFiles(urls, cap: cap)
        guard !all.isEmpty else {
            errorText = "Aucun fichier .txt/.md/.pdf à apprendre ici."; return
        }
        let files = Array(all.prefix(cap))
        var done = 0, stopped = false
        for url in files {
            if Task.isCancelled { stopped = true; break }   // « Arrêter » honoré
            done += 1
            trainingLog.append("Lecture de \(url.lastPathComponent)… (\(done)/\(files.count))")
            if let text = Self.readText(url),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try? await engine.ingest(name: name, text: text, source: url.path)
            }
        }
        let after = (try? await engine.memory(name: name)) ?? []
        lastLearned = after.filter { !before.contains($0.id) }
        facts = after
        profileText = await engine.profile(name: name)
        if stopped {
            trainingLog.append("⏹ Arrêté — \(lastLearned.count) fait(s) appris (\(done)/\(files.count) fichiers)")
        } else if all.count > files.count {
            trainingLog.append("✦ \(lastLearned.count) fait(s) appris · \(files.count)/\(all.count) fichiers (plafond \(cap))")
        } else {
            trainingLog.append("✦ \(lastLearned.count) fait(s) appris depuis \(files.count) fichier(s)")
        }
    }

    // PROTECTION (mode plein-ordinateur) : on ne descend jamais dans le système, les
    // bibliothèques, les caches ou les arbres de dev — que les vrais documents perso.
    nonisolated static let excludedDirs: Set<String> = [
        "Library", "Applications", "System", "node_modules", ".git", ".Trash",
        "Caches", ".cache", "venv", ".venv", "site-packages", "DerivedData", "Pods",
        ".build", ".npm", ".cargo", "dist", "build", "bin", "sbin", "Photos Library.photoslibrary",
    ]

    nonisolated static let maxFileBytes = 8_000_000   // sécurité : on ne lit pas un fichier énorme

    /// Flatten files + folders → the list of supported files to read (folders walked recursively),
    /// with STRICT safety: skips excluded system/dev/cache dirs, NEVER follows symbolic links
    /// (pas d'évasion hors périmètre), and ignores oversized files.
    nonisolated static func expandToFiles(_ urls: [URL], cap: Int = fileCap) -> [URL] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let en = fm.enumerator(at: u, includingPropertiesForKeys: Array(keys),
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = en?.nextObject() as? URL {
                    let rv = try? f.resourceValues(forKeys: keys)
                    if rv?.isSymbolicLink == true { en?.skipDescendants(); continue }   // ne suit pas les liens
                    if excludedDirs.contains(f.lastPathComponent) { en?.skipDescendants(); continue }
                    if supportedExt.contains(f.pathExtension.lowercased()),
                       (rv?.fileSize ?? 0) <= maxFileBytes {
                        out.append(f)
                    }
                    if out.count >= cap * 2 { break }   // hard guard on enormous trees
                }
            } else if supportedExt.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        return out
    }

    /// « Apprendre de tout mon Mac » (§4.A, plein-ordinateur LOCAL) — scanne les emplacements
    /// personnels (Documents, Bureau, Téléchargements + Accueil), 100% en local, exclusions
    /// appliquées, annulable. macOS demandera l'accès à chaque dossier protégé (ou via Accès
    /// complet au disque). Rien ne sort de la machine.
    func learnWholeMac() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["Documents", "Desktop", "Downloads"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else {
            errorText = "Emplacements personnels introuvables."; return
        }
        // Scan direct (sans persister 3 connecteurs fantômes) — annulable via « Arrêter ».
        learn(roots, full: true)
    }

    nonisolated static func readText(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" { return PDFDocument(url: url)?.string }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Local folder connectors (choose ANY folder on the Mac; persisted, re-syncable)

    private func foldersKey(_ ia: String) -> String { "ember.connectors.folders.\(ia)" }

    /// Restore the connected folders for the selected IA (display paths).
    func loadConnectedFolders() {
        guard let ia = selected?.name,
              let dict = UserDefaults.standard.dictionary(forKey: foldersKey(ia)) as? [String: Data] else {
            connectedFolders = []; return
        }
        connectedFolders = dict.keys.sorted()
    }

    func connectFolder(_ url: URL) { connectFolders([url]) }

    /// Connect one or more folders the user picked: remember them (bookmarks) and learn them now.
    /// `full` = whole-Mac scan cap. This is the « Apprentissage complet » entry point too.
    func connectFolders(_ urls: [URL], full: Bool = false) {
        guard let ia = selected?.name else {
            errorText = "Choisis (ou crée) d'abord une IA."; return
        }
        var dict = (UserDefaults.standard.dictionary(forKey: foldersKey(ia)) as? [String: Data]) ?? [:]
        for url in urls {
            if let data = try? url.bookmarkData(options: [],
                                                includingResourceValuesForKeys: nil, relativeTo: nil) {
                dict[url.path] = data
            }
        }
        UserDefaults.standard.set(dict, forKey: foldersKey(ia))
        loadConnectedFolders()
        learn(urls, full: full)
    }

    /// Re-learn a connected folder (resolve its stored bookmark).
    func resyncFolder(_ path: String) {
        guard let ia = selected?.name,
              let dict = UserDefaults.standard.dictionary(forKey: foldersKey(ia)) as? [String: Data],
              let data = dict[path] else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            errorText = "Dossier introuvable : \(path)"; return
        }
        learn([url])
    }

    func disconnectFolder(_ path: String) {
        guard let ia = selected?.name else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: foldersKey(ia)) as? [String: Data]) ?? [:]
        dict.removeValue(forKey: path)
        UserDefaults.standard.set(dict, forKey: foldersKey(ia))
        loadConnectedFolders()
    }

    /// CRUD-delete on learning: forget every fact a connector taught, then remove the connector.
    func forgetConnector(_ path: String) async {
        guard let name = selected?.name else { return }
        _ = try? await engine.forgetSource(name: name, prefix: path)
        disconnectFolder(path)
        await loadFacts(name)
    }

    /// CRUD-delete on the Apple Notes source: forget every fact learned from Notes.
    func forgetNotes() async {
        guard let name = selected?.name else { return }
        _ = try? await engine.forgetSource(name: name, prefix: "notes:apple")
        await loadFacts(name)
    }

    /// « Remettre » : re-learn ALL connected folders at once (refresh the whole set).
    func resyncAll() {
        guard let ia = selected?.name,
              let dict = UserDefaults.standard.dictionary(forKey: foldersKey(ia)) as? [String: Data] else { return }
        var urls: [URL] = []
        for data in dict.values {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                  bookmarkDataIsStale: &stale) { urls.append(url) }
        }
        if !urls.isEmpty { learn(urls, full: true) }
    }

    /// REAL Apple Notes connector (§4.A) — read the user's notes locally and learn facts from them.
    func teachNotes() async {
        guard let name = selected?.name else {
            errorText = "Choisis (ou crée) d'abord une IA."; return
        }
        guard !isLearning else { return }
        isLearning = true; trainingLog = []; defer { isLearning = false }
        trainingLog.append("Lecture de tes notes Apple…")
        do {
            let r = try await engine.ingestNotes(name: name)
            if r.total == 0 {
                errorText = "Aucune note accessible — autorise Ember dans Réglages › Confidentialité › Automatisation › Notes."
            } else {
                trainingLog.append("✦ \(r.learned) fait(s) appris depuis \(r.notes) note(s) (sur \(r.total))")
            }
            await loadFacts(name)
        } catch {
            errorText = "Lecture des notes impossible : \(error.localizedDescription)"
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

    // MARK: - Génération locale d'éléments (la plus-value : Her FABRIQUE des choses, en local)

    struct GeneratedDoc: Identifiable, Equatable { let id = UUID(); let title: String; let path: URL }
    @Published var generating = false
    @Published var lastGenerated: GeneratedDoc?

    /// Generate a real document LOCALLY from a brief, save it (openable), and surface it.
    func generateDocument(_ brief: String) async {
        let b = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, let name = selected?.name, !generating else { return }
        generating = true; defer { generating = false }
        do {
            let r = try await engine.generate(name: name, brief: b)
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ember", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let slug = Self.slug(r.title)
            let url = dir.appendingPathComponent("\(slug).md")
            try r.content.write(to: url, atomically: true, encoding: .utf8)
            lastGenerated = GeneratedDoc(title: r.title, path: url)
        } catch {
            errorText = "Génération impossible : \(error.localizedDescription)"
        }
    }

    nonisolated static func slug(_ s: String) -> String {
        let base = s.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let cleaned = base.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var out = String(cleaned)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "document" : String(out.prefix(48))
    }

    func openGenerated() { if let u = lastGenerated?.path { NSWorkspace.shared.open(u) } }
    func revealGenerated() { if let u = lastGenerated?.path { NSWorkspace.shared.activateFileViewerSelecting([u]) } }

    func saveSettings(_ name: String, persona: String, maxTokens: Int, temperature: Double) async {
        // The tone chip (personaSel) is sent as its own field → the daemon turns it into a real
        // instruction in the persona prompt (no longer cosmetic), without polluting the free text.
        do { try await engine.setSettings(name: name, persona: persona, maxTokens: maxTokens,
                                          temperature: temperature, tone: personaSel) }
        catch { errorText = error.localizedDescription }
    }

    private var chatTask: Task<Void, Never>?

    /// Start a reply (cancellable). The orb « interrompre » (§3) cancels this.
    func sendChat(_ prompt: String) {
        chatTask?.cancel()
        chatTask = Task { await self.send(prompt) }
    }
    /// Interrupt the running generation — keeps the text already streamed (§3 « interrompre »).
    func stopGeneration() { chatTask?.cancel() }

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
                if Task.isCancelled { break }
                if acc.isEmpty { isBusy = false; talking = true }   // first token → parle (ondulations §3)
                acc += delta
                if idx < messages.count { messages[idx].text = acc }
            }
            if Task.isCancelled, idx < messages.count {
                messages[idx].text = acc.isEmpty ? "(interrompu)" : acc + " ⏹"
            } else if acc.isEmpty, idx < messages.count {
                messages[idx].text = "…"
            }
        } catch {
            if Task.isCancelled || (error is CancellationError) {
                if idx < messages.count { messages[idx].text = acc.isEmpty ? "(interrompu)" : acc + " ⏹" }
            } else if idx < messages.count {
                messages[idx].text = "⚠️ \(error.localizedDescription)"
            }
        }
    }
}
