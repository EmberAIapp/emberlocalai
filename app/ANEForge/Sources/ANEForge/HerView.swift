import SwiftUI

/// Mode Her — mains-libres, conversation fluide. The conversation is the spine, UNDER the orb:
///   • CONVERSATION (la colonne) : trace écrite « Toi » / « Ember », déroulable, sous l'orbe + signal.
///   • TRAVAIL inline : sous le message qui l'a déclenché, un bloc dépliable montrant en détail ce
///     que fait l'agent (→ on voit le lien travail ↔ conversation).
///   • VUE D'ENSEMBLE : une carte synthétique à côté quand le travail est conséquent.
/// Voix locale (Kokoro) ; l'agent de travail = DeepSeek (cloud), rien sans permission.
struct HerView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var speech = SpeechController()
    @State private var pulse = false

    var body: some View {
        ZStack {
            RadialGradient(
                stops: [.init(color: Color(hexv: 0x2a1812), location: 0),
                        .init(color: Color(hexv: 0x130b08), location: 0.6),
                        .init(color: Color(hexv: 0x080404), location: 1)],
                center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: 900)
            .ignoresSafeArea()
            // Un seul fil, centré : conversation, travail et éléments générés vivent dans la même
            // colonne chronologique. Plus de panneau latéral qui décale le fil (§ « pas de saut »).
            ConversationColumn(speech: speech, onMic: toggleVoice)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 44).padding(.top, 26).padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            // Voice permission is requested only when the user actually engages voice — tapping the
            // mic (startVoice) or arming « Ok Ember » (onChange wakeWanted) — never eagerly on launch.
            speech.onTranscript = { t in
                // A permission is waiting → answer it by voice ("oui"/"non"), truly mains libres.
                if state.agentPendingGate != nil, let yes = state.voiceGateAnswer(t) {
                    state.resolveAgentGate(yes, remember: yes)   // spoken "oui" also remembers the scope this session
                } else if state.agentPendingGate != nil {
                    return                                        // ignore chatter while a gate is open
                } else if state.voiceSession && state.isEcho(t) {
                    // The mic caught Ember's OWN voice (no echo cancellation) → ignore it and
                    // keep listening for the real user. Kills the self-talk feedback loop.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if state.voiceSession, !speech.listening, !speech.speaking, !state.isBusy, !state.agentBusy {
                            speech.toggleListening(locale: SpeechController.locale(for: state.herLang))
                        }
                    }
                } else if state.voiceSession && state.isStopPhrase(t) {
                    state.voiceSession = false; speech.stopSpeaking()
                } else {
                    state.herSend(t)
                }
            }
        }
        .onChange(of: state.agentPendingGate?.id) { _, gate in
            // In a voice session, open the mic so the user can say "oui"/"non" to the permission.
            if gate != nil, state.voiceSession, !speech.listening, !speech.speaking {
                speech.toggleListening(locale: micLocale())
            }
        }
        .onChange(of: speech.listening) { _, v in state.herListening = v; if !v { armWakeIfWanted() } }
        .onChange(of: speech.speaking)  { _, v in
            state.herSpeaking = v
            if state.voiceSession && !v && !speech.fullDuplex { reopenMic() }
            else if !v { armWakeIfWanted() }            // Ember a fini de parler → ré-arme « Ok Ember »
        }
        // « Ok Ember » détecté → démarre la conversation mains-libres (sans toucher au bouton).
        .onChange(of: speech.wakeFired) { _, _ in
            if state.wakeWanted && !state.voiceSession { startVoice() }
        }
        .onChange(of: state.wakeWanted) { _, on in
            if on { speech.requestAuth(); armWakeIfWanted() } else { speech.stopWakeListening() }
        }
        .onChange(of: speech.wakeFailed) { _, failed in
            guard failed else { return }
            state.wakeWanted = false        // on désarme : pas de boucle qui draine
            state.errorText = "“Ok Ember” needs ON-DEVICE speech recognition "
                            + "(unavailable for this language/machine, or permission denied). The mic button is still available, though."
        }
        .onChange(of: state.voiceSession) { _, on in if !on { armWakeIfWanted() } }
        .onChange(of: speech.authorized) { _, ok in if ok { armWakeIfWanted() } }   // permission accordée → arme
        .onChange(of: state.herSpeak) { _, req in
            guard let req else { return }
            state.lastSpoken = req.text                         // remember for echo rejection
            Task {
                if !req.text.isEmpty, let data = await state.ttsData(req.text, req.lang) { speech.playWav(data, text: req.text) }
                else if !req.text.isEmpty { speech.speakFallback(req.text, locale: SpeechController.locale(for: req.lang)) }
                else if state.voiceSession { reopenMic() }
            }
        }
        .onDisappear { speech.endVoice(); speech.stopWakeListening() }
    }

    private func micLocale() -> String { SpeechController.locale(for: state.herLang) }
    private func startVoice() {
        // Garde permission : sans autorisation, le micro était un cul-de-sac silencieux (« la voix ne
        // marche pas »). On guide l'utilisateur au lieu d'échouer sans rien dire.
        guard speech.authorized else {
            speech.requestAuth()
            state.errorText = "To talk to Ember, allow “Microphone” and “Speech Recognition” "
                            + "in System Settings › Privacy & Security, then try again."
            return
        }
        speech.stopWakeListening()                        // le micro passe à la conversation
        speech.allowFullDuplex = state.fullDuplexWanted   // opt-in talk-over, else reliable turn-based
        state.voiceSession = true
        speech.startVoice(locale: micLocale())
    }
    private func endVoice() { state.voiceSession = false; speech.endVoice(); armWakeIfWanted() }
    private func toggleVoice() { if state.voiceSession { endVoice() } else { startVoice() } }

    /// Ré-arme l'écoute « Ok Ember » dès que le système redevient inactif (et si l'utilisateur le veut).
    private func armWakeIfWanted() {
        guard state.wakeWanted else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)   // laisse le micro précédent se libérer
            guard state.wakeWanted, !state.voiceSession, !speech.listening,
                  !speech.speaking, !speech.wakeListening else { return }
            speech.startWakeListening(locale: micLocale())
        }
    }
    private func reopenMic() {
        Task { @MainActor in
            // longer settle so the speaker's tail/echo of Ember's voice has died down before
            // the mic reopens (no AEC) — combined with echo-rejection in onTranscript.
            try? await Task.sleep(nanoseconds: 700_000_000)
            if state.voiceSession, !speech.listening, !speech.speaking, !state.isBusy, !state.agentBusy {
                speech.toggleListening(locale: micLocale())
            }
        }
    }

}

// MARK: - Animated sinusoidal signal, in the Ember colour theme

private struct VoiceWave: View {
    var level: CGFloat
    var paused: Bool = false        // au repos on fige l'animation (zéro CPU constant)
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let midY = size.height / 2
                let lvl = min(max(level, 0), 1)
                let amp = (0.08 + 0.82 * lvl) * (size.height / 2 - 2)
                let w = size.width
                func wave(_ freq: Double, _ speed: Double, _ scale: CGFloat) -> Path {
                    var p = Path(); var first = true; var x: CGFloat = 0
                    while x <= w {
                        let rel = Double(x / w)
                        let env = sin(rel * .pi)
                        let y = midY + CGFloat(sin(rel * .pi * freq - t * speed)) * amp * scale * CGFloat(env)
                        let pt = CGPoint(x: x, y: y)
                        if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
                        x += 2
                    }
                    return p
                }
                let grad = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Color(hexv: 0xffb877), Color(hexv: 0xff7a3a), Color(hexv: 0xff5a28)]),
                    startPoint: .zero, endPoint: CGPoint(x: w, y: 0))
                ctx.stroke(wave(6, 3.0, 1.0), with: grad, lineWidth: 2.5)
                ctx.opacity = 0.45
                ctx.stroke(wave(11, 4.4, 0.42), with: grad, lineWidth: 1.5)
            }
        }
    }
}

// MARK: - The conversation column: orb + signal on top, transcript (with inline work) below

private struct ConversationColumn: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var speech: SpeechController
    var onMic: () -> Void
    @State private var draft = ""
    @State private var workExpanded = false   // replié par défaut → on voit l'action en cours, on déplie pour le détail

    private var level: CGFloat {
        if speech.listening { return 0.9 }
        if state.herSpeaking { return 0.6 }
        if state.agentBusy || state.isBusy { return 0.32 }
        return 0.14
    }
    // The live transcript to show — but blank it out if it's actually Ember's own voice picked
    // up by the mic (echo), so her words never appear in your input bar.
    private var liveText: String {
        let p = speech.partial
        return (p.isEmpty || state.herSpeaking || state.isEcho(p)) ? "" : p
    }

    // L'orbe ne montre QUE l'état vivant — jamais la dernière réponse (elle est déjà dans le fil → zéro doublon).
    private var caption: String {
        if speech.listening { return liveText.isEmpty ? "Listening…" : liveText }
        if state.isBusy { return "Thinking…" }
        if state.agentBusy { return "On it…" }
        if state.talking || state.herSpeaking { return "…" }
        if !active {
            return state.voiceSession ? "I'm listening — speak whenever you like." : "Talk to me, or hand me a task."
        }
        return state.voiceSession ? "I'm listening — speak whenever you like." : "I'm listening."
    }

    /// Le fil « vit » dès qu'il y a un échange, un travail ou un document — l'orbe se fait alors compact.
    private var active: Bool { !state.herConversation.isEmpty || state.generating || state.lastGenerated != nil }
    private var canSend: Bool { !state.agentBusy && !draft.trimmingCharacters(in: .whitespaces).isEmpty }
    private func send() { let t = draft; draft = ""; state.herSend(t) }

    var body: some View {
        VStack(spacing: 16) {
            presence
            thread          // le fil unique : échange + travail inline + éléments générés
            input
            footer
        }
    }

    // Présence — l'orbe EST le bouton (§3) : travail → interrompre ; sinon → voix.
    // Grand au repos ; compact dès que le fil vit, pour lui laisser la place (présence qui s'efface).
    private var presence: some View {
        let orbSize: CGFloat = active ? 54 : 88
        return VStack(spacing: active ? 10 : 18) {
            Button {
                if state.isBusy || state.agentBusy || state.talking { state.interruptHer() }
                else { onMic() }
            } label: {
                EmberOrb(mode: state.orbMode, size: orbSize).frame(width: orbSize, height: orbSize)
            }
            .buttonStyle(.plain)
            .help(state.isBusy || state.agentBusy || state.talking ? "Interrupt" : "Speak (hands-free)")
            VoiceWave(level: level, paused: level <= 0.15 && !state.isBusy && !state.agentBusy)
                .frame(width: active ? 240 : 320, height: active ? 44 : 70)
            Text(LocalizedStringKey(caption))
                .font(.emberSerif(active ? 15 : 18, weight: .regular).italic())
                .foregroundStyle(Color(hexv: 0xd8b9a6))
                .multilineTextAlignment(.center).lineSpacing((active ? 15 : 18) * 0.4)
                .frame(maxWidth: 460).lineLimit(2)
                .animation(.easeInOut(duration: 0.3), value: caption)
        }
        .padding(.top, active ? 2 : 8)
        .animation(.easeInOut(duration: 0.35), value: active)
    }

    // « Généré » — le document, posé DANS le fil (là où il a été produit), ouvrable.
    @ViewBuilder private var generatedCard: some View {
        if state.generating || state.lastGenerated != nil {
            VStack(alignment: .leading, spacing: 3) {
                Text("EMBER · GENERATED").font(.system(size: 9.5, weight: .medium)).tracking(0.8)
                    .foregroundStyle(Color(hexv: 0x8a9b8e))
                HStack(spacing: 10) {
                    if state.generating {
                        Image(systemName: "doc.badge.gearshape").font(.system(size: 13)).foregroundStyle(Color(hexv: 0xffb877))
                        Text("Generating document… (local)").font(.system(size: 12)).foregroundStyle(Color(hexv: 0xe8c4a8))
                        Spacer(minLength: 0)
                    } else if let doc = state.lastGenerated {
                        Image(systemName: "doc.text.fill").font(.system(size: 14)).foregroundStyle(Color(hexv: 0x9fd9ad))
                        Text(doc.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hexv: 0xecd9c9)).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { state.openGenerated() } label: { genPill("Open") }.buttonStyle(.plain)
                        Button { state.revealGenerated() } label: { genPill("Reveal") }.buttonStyle(.plain)
                        Button { state.lastGenerated = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(hexv: 0x8a7d75)).frame(width: 20, height: 20)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 9).padding(.horizontal, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color(hexv: 0x5fd07a).opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color(hexv: 0x5fd07a).opacity(0.22), lineWidth: 1))
            }
            .padding(.top, 2)
        }
    }
    private func genPill(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color(hexv: 0x9fd9ad))
            .padding(.vertical, 4).padding(.horizontal, 11)
            .background(Capsule().fill(Color(hexv: 0x5fd07a).opacity(0.12)))
    }
    private func generateDoc() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !state.generating else { return }
        draft = ""
        Task { await state.generateDocument(t) }
    }

    // Une création passée, restaurée à sa place dans le fil (carte ouvrable).
    private func creationRow(_ turn: HerTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("EMBER · GENERATED").font(.system(size: 9.5, weight: .medium)).tracking(0.8)
                .foregroundStyle(Color(hexv: 0x8a9b8e))
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill").font(.system(size: 14)).foregroundStyle(Color(hexv: 0x9fd9ad))
                Text(turn.text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hexv: 0xecd9c9)).lineLimit(1)
                Spacer(minLength: 0)
                if let p = turn.path {
                    Button { state.openPath(p) } label: { genPill("Open") }.buttonStyle(.plain)
                    Button { state.revealPath(p) } label: { genPill("Reveal") }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color(hexv: 0x5fd07a).opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color(hexv: 0x5fd07a).opacity(0.22), lineWidth: 1))
        }
        .padding(.top, 2)
    }

    // Le fil unique : un seul flux chronologique (pas de séparateur « — L'ÉCHANGE — »).
    @ViewBuilder private var thread: some View {
        if !active {
            Text("Say “Hello” or ask me anything — I answer out loud. Hand me a task (“tidy up my screenshots”) and you'll watch the work unfold here, then what I made.")
                .font(.system(size: 12.5)).foregroundStyle(Color.emberMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440).frame(maxHeight: .infinity, alignment: .center)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {   // lazy → ne rend que le visible (fil long fluide)
                        ForEach(state.herConversation) { turn in
                            if turn.kind == .creation { creationRow(turn) }   // document restauré, dans le fil
                            else { bubble(turn) }
                            if turn.working { WorkInline(expanded: $workExpanded) }
                        }
                        generatedCard          // l'élément en cours de génération (session vivante)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxHeight: .infinity)
                // Pendant le streaming, herConversation change à CHAQUE token : on suit le bas SANS
                // animation (l'animation par token saccadait toute l'interface). Saut instantané = fluide.
                .onChange(of: state.herConversation) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: state.agentEvents) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: state.generating) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: state.lastGenerated?.title) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                // « Revenir à cette étape » depuis l'Historique : on défile jusqu'au tour visé.
                .onChange(of: state.scrollTarget) { _, t in
                    guard let t else { return }
                    withAnimation { proxy.scrollTo(t, anchor: .center) }
                    state.scrollTarget = nil
                }
                .onAppear {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 380_000_000)   // laisse la transition + le layout se poser
                        if let t = state.scrollTarget {
                            withAnimation { proxy.scrollTo(t, anchor: .center) }   // « Revenir » → l'étape visée
                            state.scrollTarget = nil
                        } else {
                            proxy.scrollTo("bottom", anchor: .bottom)              // fil restauré → message le plus récent
                        }
                    }
                }
            }
        }
    }

    private func bubble(_ turn: HerTurn) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if turn.role == .user { Spacer(minLength: 60) }
            VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 3) {
                Text(turn.role == .user ? "YOU" : "EMBER")
                    .font(.system(size: 9.5, weight: .medium)).tracking(0.8)
                    .foregroundStyle(turn.role == .user ? Color(hexv: 0x8a7a70) : Color(hexv: 0xc79a82))
                if turn.role == .ember {
                    Text(turn.text.isEmpty ? "…" : turn.text)
                        .font(.emberSerif(14.5, weight: .regular)).foregroundStyle(Color(hexv: 0xf0ddcf))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 9).padding(.horizontal, 13)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color(hexv: 0xff783c).opacity(0.09)))
                } else {
                    Text(turn.text)
                        .font(.system(size: 13)).foregroundStyle(Color(hexv: 0xe8d4c6))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 9).padding(.horizontal, 13)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.06)))
                }
            }
            if turn.role == .ember { Spacer(minLength: 60) }
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            Button(action: onMic) {
                Image(systemName: state.voiceSession ? "stop.circle.fill" : (speech.listening ? "mic.fill" : "mic"))
                    .font(.system(size: 18))
                    .foregroundStyle(state.voiceSession || speech.listening ? Color(hexv: 0xff5a46) : Color(hexv: 0x9a8d84))
                    .symbolEffect(.pulse, isActive: speech.listening)
            }
            .buttonStyle(.plain).help(state.voiceSession ? "Stop the conversation" : "Voice conversation (hands-free)")

            TextField(LocalizedStringKey(speech.listening ? (liveText.isEmpty ? "Listening…" : liveText)
                       : (state.voiceSession ? "In conversation — tap to stop" : "Talk or type to Ember…")), text: $draft)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.emberInk)
                .onSubmit { if canSend { send() } }

            // 📄 générer un VRAI document local à partir du brief
            Button(action: generateDoc) {
                Image(systemName: state.generating ? "doc.badge.gearshape" : "doc.badge.plus")
                    .font(.system(size: 17)).foregroundStyle(Color(hexv: 0xc79a82))
            }
            .buttonStyle(.plain)
            .disabled(state.generating || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Generate a document (local)")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundStyle(canSend ? Color(hexv: 0xff7a3a) : Color.white.opacity(0.2))
            }
            .buttonStyle(.plain).disabled(!canSend)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hexv: 0xff965a).opacity(0.25), lineWidth: 1))
        .frame(maxWidth: 560)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Color(hexv: 0x7fd095))
            Text(LocalizedStringKey(state.voiceSession && speech.fullDuplex ? "Voice 100% local · duplex" : "Voice & conversation, 100% local"))
                .font(.system(size: 11)).foregroundStyle(Color(hexv: 0x9bbfa3))
            Spacer(minLength: 6)
            Button { state.wakeWanted.toggle() } label: {
                pill(on: state.wakeWanted, icon: speech.wakeListening ? "waveform.badge.mic" : "mic.badge.plus",
                     label: state.wakeWanted ? "Ok Ember ON" : "Ok Ember")
            }
            .buttonStyle(.plain)
            .help("Say “Ok Ember” to start hands-free — always-listening, 100% on your Mac. The mic stays active while armed.")
            Button { state.fullDuplexWanted.toggle() } label: {
                pill(on: state.fullDuplexWanted, icon: "waveform", label: state.fullDuplexWanted ? "Duplex ON" : "Duplex")
            }
            .buttonStyle(.plain)
            .help("Talk over Ember while she speaks (echo cancellation). Experimental — best with headphones.")
            Button { state.trustMode.toggle() } label: {
                pill(on: state.trustMode, icon: state.trustMode ? "bolt.shield.fill" : "bolt.shield",
                     label: state.trustMode ? "Trust ON" : "Trust")
            }
            .buttonStyle(.plain)
            .help("Auto-allow non-sensitive actions this session (sending/deleting is always confirmed).")
        }
    }

    private func pill(on: Bool, icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon); Text(LocalizedStringKey(label))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(on ? Color(hexv: 0xffb877) : Color(hexv: 0x9a8d84))
        .padding(.vertical, 4).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color(hexv: 0xff7a3a).opacity(0.16) : Color.white.opacity(0.05)))
    }
}

// MARK: - Inline work block (anchored under the message that triggered it)

private struct WorkInline: View {
    @EnvironmentObject var state: AppState
    @Binding var expanded: Bool

    private var steps: Int { state.agentEvents.filter { ["tool", "observation", "plan"].contains($0.type) }.count }
    private var open: Bool { expanded || state.agentPendingGate != nil }

    // Dernière action lisible → suivi vivant visible sans déplier (la « vue d'ensemble » dans le fil).
    private var liveSummary: String? {
        guard let e = state.agentEvents.last(where: {
            ["observation", "tool", "plan", "error"].contains($0.type) && !($0.text.isEmpty && $0.detail.isEmpty)
        }) else { return nil }
        return e.text.isEmpty ? e.detail : e.text
    }

    var body: some View {
        if !state.agentEvents.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(Color(hexv: 0xffa050).opacity(0.5)).frame(width: 2)
                VStack(alignment: .leading, spacing: 8) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: state.agentBusy ? "gearshape.2" : "checkmark.seal").font(.system(size: 12))
                                .foregroundStyle(Color(hexv: 0xffa050))
                            Text(verbatim: String(format: NSLocalizedString(steps <= 1 ? "Work · %lld step" : "Work · %lld steps", comment: "agent step counter"), steps))
                                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color(hexv: 0xffa050))
                            Spacer()
                            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 11))
                                .foregroundStyle(Color(hexv: 0x8a7a70))
                            Text(open ? "collapse" : "expand").font(.system(size: 11)).foregroundStyle(Color(hexv: 0x8a7a70))
                        }
                    }
                    .buttonStyle(.plain)
                    if open {
                        ForEach(state.agentEvents) { e in
                            HerEventRow(event: e,
                                        onAllow: { state.resolveAgentGate(true) },
                                        onAlways: { state.resolveAgentGate(true, remember: true) },
                                        onDeny: { state.resolveAgentGate(false) })
                        }
                        // Honnêteté §2.4 : le travail tourne sur DeepSeek (cloud) — repris ici depuis la
                        // « Vue d'ensemble » (supprimée au profit du fil unique).
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "cloud").font(.system(size: 10)).foregroundStyle(Color(hexv: 0xc9a98f))
                            Text("Work runs on DeepSeek (cloud) · the plan and results pass through it")
                                .font(.system(size: 10)).foregroundStyle(Color(hexv: 0xc9a98f))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    } else if let s = liveSummary {
                        Text(s).font(.system(size: 11.5)).foregroundStyle(Color(hexv: 0xbfae9f))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.leading, 11)
                Spacer(minLength: 40)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - One agent event row (work detail)

private struct HerEventRow: View {
    let event: AgentEvent
    let onAllow: () -> Void
    var onAlways: () -> Void = {}
    let onDeny: () -> Void

    var body: some View {
        switch event.type {
        case "gate":               gateRow
        case "done", "message":    EmptyView()
        case "error":              stepRow(icon: "exclamationmark.triangle.fill", tint: Color(hexv: 0xff6b5a), title: "Error", detail: event.text)
        case "tool":               stepRow(icon: toolIcon, tint: Color(hexv: 0xffa050), title: LocalizedStringKey(toolTitle), detail: event.detail)
        case "observation":        stepRow(icon: event.denied ? "xmark.circle.fill" : "checkmark.circle.fill",
                                            tint: event.denied ? Color(hexv: 0xff6b5a) : Color(hexv: 0x7fd095),
                                            title: nil, detail: event.text)
        case "plan":               stepRow(icon: "target", tint: Color(hexv: 0xc79a82), title: "Task", detail: event.text)
        default:                   EmptyView()
        }
    }

    private var toolIcon: String {
        switch event.tool {
        case "list_facts", "search_memory": return "brain"
        case "read_file", "list_dir", "reveal_in_finder": return "folder"
        case "write_note":                   return "square.and.pencil"
        case "open_app":                     return "app.badge"
        case "open_url":                     return "safari"
        case "spotlight_search":             return "magnifyingglass"
        case "search_text":                  return "text.magnifyingglass"
        case "read_clipboard":               return "doc.on.clipboard"
        case "notify":                       return "bell"
        case "read_notes", "create_note":    return "note.text"
        case "read_reminders", "create_reminder": return "checklist"
        case "read_calendar":                return "calendar"
        case "create_event":                 return "calendar.badge.plus"
        case "write_clipboard":              return "doc.on.clipboard"
        case "move_file":                    return "arrow.right.doc.on.clipboard"
        case "copy_file":                    return "doc.on.doc"
        case "music_control":                return "music.note"
        case "draft_mail":                   return "envelope"
        case "run_shortcut":                 return "bolt"
        default:                             return "gearshape"
        }
    }
    private var toolTitle: String {
        switch event.tool {
        case "list_facts":      return "Checks memory"
        case "search_memory":   return "Searches memory"
        case "list_dir":        return "Lists a folder"
        case "read_file":       return "Reads a file"
        case "write_note":      return "Writes a note"
        case "open_app":        return "Opens an app"
        case "open_url":        return "Opens a link"
        case "reveal_in_finder": return "Reveals in Finder"
        case "spotlight_search": return "Searches for files"
        case "search_text":     return "Searches text"
        case "read_clipboard":  return "Reads the clipboard"
        case "notify":          return "Notifies"
        case "read_notes":      return "Reads your notes"
        case "read_reminders":  return "Reads your reminders"
        case "read_calendar":   return "Reads your calendar"
        case "write_clipboard": return "Copies to the clipboard"
        case "create_note":     return "Creates a note"
        case "create_reminder": return "Creates a reminder"
        case "create_event":    return "Creates an event"
        case "move_file":       return "Moves a file"
        case "copy_file":       return "Copies a file"
        case "music_control":   return "Controls music"
        case "draft_mail":      return "Prepares a mail draft"
        case "run_shortcut":    return "Runs a shortcut"
        default:                return event.tool
        }
    }

    private func stepRow(icon: String, tint: Color, title: LocalizedStringKey?, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12.5)).foregroundStyle(tint).frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                if let title { Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hexv: 0xe8d4c6)) }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color.emberMuted)
                        .lineLimit(title == nil ? 4 : 2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gateDesc: LocalizedStringKey {
        switch event.tool {
        case "__cloud__":        return "Send your request — and the tool results (files, notes, memory read) — to DeepSeek (cloud) for this task. Nothing has left yet."
        case "list_facts":       return "Read your personal memory facts"
        case "search_memory":    return "Search your personal memory"
        case "read_clipboard":   return "Read your clipboard (it may contain passwords / codes)"
        case "write_note":       return "Write “\(event.detail)” to your drafts"
        case "read_file":        return "Read “\(event.detail)”"
        case "list_dir":         return "List “\(event.detail)”"
        case "open_app":         return "Open the app “\(event.detail)”"
        case "open_url":         return "Open the link “\(event.detail)”"
        case "reveal_in_finder": return "Reveal “\(event.detail)” in Finder"
        case "spotlight_search": return "Search “\(event.detail)” on the Mac"
        case "search_text":      return "Search for text in “\(event.detail)”"
        case "read_notes":       return "Read your notes"
        case "read_reminders":   return "Read your reminders"
        case "read_calendar":    return "Read today's calendar"
        case "write_clipboard":  return "Copy text to the clipboard"
        case "create_note":      return "Create the note “\(event.detail)”"
        case "create_reminder":  return "Create the reminder “\(event.detail)”"
        case "create_event":     return "Create the event “\(event.detail)”"
        case "move_file":        return "Move “\(event.detail)”"
        case "copy_file":        return "Copy a file"
        case "music_control":    return "Control music (\(event.detail))"
        case "draft_mail":       return "Prepare a mail draft “\(event.detail)” (not sent)"
        case "run_shortcut":     return "Run the shortcut “\(event.detail)”"
        default:                 return LocalizedStringKey(event.tool)
        }
    }

    // Tools whose RESULT (content read) is sent to the cloud brain → warn before consenting.
    private var cloudWarn: String? {
        let exfil: Set<String> = ["read_file", "list_dir", "read_notes", "read_reminders",
                                  "read_calendar", "spotlight_search", "search_text",
                                  "read_clipboard", "list_facts", "search_memory"]
        return exfil.contains(event.tool) ? "The content read will be sent to DeepSeek (cloud)." : nil
    }

    // Tier-3 scopes always re-ask (no "Toujours"): the cloud egress, shortcuts, sends, deletes…
    private var isTier3: Bool {
        ["Cloud (DeepSeek)", "Raccourcis", "Mail-envoi", "Messages-envoi",
         "Agenda-invitation", "Fichiers-suppr", "Écran", "Presse-papiers-lecture"].contains(event.scope)
    }

    private var gateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 12.5)).foregroundStyle(Color(hexv: 0xffd089)).frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Permission: \(event.scope)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hexv: 0xffd089))
                    Text(gateDesc).font(.system(size: 11)).foregroundStyle(Color.emberMuted).fixedSize(horizontal: false, vertical: true)
                    if let warn = cloudWarn {
                        HStack(spacing: 5) {
                            Image(systemName: "cloud.fill").font(.system(size: 9))
                            Text(LocalizedStringKey(warn)).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 10)).foregroundStyle(Color(hexv: 0xff9a5a)).padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button(action: onAllow)  { gateLabel("Allow", fill: true) }.buttonStyle(.plain)
                if !isTier3 {
                    Button(action: onAlways) { gateLabel("Always", fill: false) }.buttonStyle(.plain)
                }
                Button(action: onDeny)   { gateLabel("Deny", fill: false) }.buttonStyle(.plain)
            }
            .padding(.leading, 27)
            Text(isTier3
                 ? "Sensitive action — Ember will ask you every time (no “always”). You can answer “yes” / “no” out loud."
                 : "“Always” = don't ask again for THIS path this session. You can also answer “yes” / “no” out loud.")
                .font(.system(size: 10)).foregroundStyle(Color(hexv: 0x8a7a70))
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 27)
        }
        .padding(.vertical, 8).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hexv: 0xffc850).opacity(0.08)))
    }

    private func gateLabel(_ t: LocalizedStringKey, fill: Bool) -> some View {
        Text(t).font(.system(size: 11.5, weight: fill ? .semibold : .medium))
            .foregroundStyle(fill ? Color(hexv: 0x1a0f0a) : Color(hexv: 0xb09a8c))
            .padding(.vertical, 5).padding(.horizontal, 12)
            .background(
                Group {
                    if fill {
                        RoundedRectangle(cornerRadius: 13).fill(LinearGradient(
                            colors: [Color(hexv: 0xffb877), Color(hexv: 0xff7a3a)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }
                }
            )
    }
}
