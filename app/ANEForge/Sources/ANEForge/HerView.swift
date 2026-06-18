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

    private var showOverview: Bool {
        state.agentBusy || state.agentEvents.contains { $0.type == "tool" || $0.type == "gate" }
    }

    var body: some View {
        ZStack {
            RadialGradient(
                stops: [.init(color: Color(hexv: 0x2a1812), location: 0),
                        .init(color: Color(hexv: 0x130b08), location: 0.6),
                        .init(color: Color(hexv: 0x080404), location: 1)],
                center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: 900)
            .ignoresSafeArea()
            HStack(alignment: .top, spacing: 22) {
                ConversationColumn(speech: speech, onMic: toggleVoice).frame(maxWidth: 640)
                if showOverview { OverviewCard().frame(width: 286) }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44).padding(.top, 26).padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            speech.requestAuth()
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
        .onChange(of: speech.listening) { _, v in state.herListening = v }
        .onChange(of: speech.speaking)  { _, v in
            state.herSpeaking = v
            if state.voiceSession && !v && !speech.fullDuplex { reopenMic() }
        }
        .onChange(of: state.herSpeak) { _, req in
            guard let req else { return }
            state.lastSpoken = req.text                         // remember for echo rejection
            Task {
                if !req.text.isEmpty, let data = await state.ttsData(req.text, req.lang) { speech.playWav(data, text: req.text) }
                else if !req.text.isEmpty { speech.speakFallback(req.text, locale: SpeechController.locale(for: req.lang)) }
                else if state.voiceSession { reopenMic() }
            }
        }
        .onDisappear { speech.endVoice() }
    }

    private func micLocale() -> String { SpeechController.locale(for: state.herLang) }
    private func startVoice() {
        speech.allowFullDuplex = state.fullDuplexWanted   // opt-in talk-over, else reliable turn-based
        state.voiceSession = true
        speech.startVoice(locale: micLocale())
    }
    private func endVoice() { state.voiceSession = false; speech.endVoice() }
    private func toggleVoice() { if state.voiceSession { endVoice() } else { startVoice() } }
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
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
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
    @State private var workExpanded = true

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

    private var caption: String {
        if speech.listening { return liveText.isEmpty ? "À l'écoute…" : liveText }
        if let last = state.herConversation.last(where: { $0.role == .ember && !$0.text.isEmpty }) { return last.text }
        return state.voiceSession ? "Je t'écoute — parle quand tu veux." : "Parle-moi, ou confie-moi une tâche."
    }
    private var canSend: Bool { !state.agentBusy && !draft.trimmingCharacters(in: .whitespaces).isEmpty }
    private func send() { let t = draft; draft = ""; state.herSend(t) }

    var body: some View {
        VStack(spacing: 16) {
            // Presence — l'orbe EST le bouton (§3) : pendant le travail → interrompre ; sinon → voix.
            VStack(spacing: 18) {
                Button {
                    if state.isBusy || state.agentBusy || state.talking { state.interruptHer() }
                    else { onMic() }
                } label: {
                    EmberOrb(mode: state.orbMode, size: 88).frame(width: 88, height: 88)
                }
                .buttonStyle(.plain)
                .help(state.isBusy || state.agentBusy || state.talking ? "Interrompre" : "Parler (mains libres)")
                VoiceWave(level: level).frame(width: 320, height: 70)
                Text(caption)
                    .font(.emberSerif(18, weight: .regular).italic())
                    .foregroundStyle(Color(hexv: 0xd8b9a6))
                    .multilineTextAlignment(.center).lineSpacing(18 * 0.4)
                    .frame(maxWidth: 460).lineLimit(3)
                    .animation(.easeInOut(duration: 0.3), value: caption)
            }
            .padding(.top, 8)

            transcript

            genBanner
            input
            footer
        }
    }

    // « Généré » — progression puis le document généré (ouvrable), dans Her.
    @ViewBuilder private var genBanner: some View {
        if state.generating || state.lastGenerated != nil {
            HStack(spacing: 10) {
                if state.generating {
                    Image(systemName: "doc.badge.gearshape").font(.system(size: 13)).foregroundStyle(Color(hexv: 0xffb877))
                    Text("Génération du document… (local)").font(.system(size: 12)).foregroundStyle(Color(hexv: 0xe8c4a8))
                    Spacer(minLength: 0)
                } else if let doc = state.lastGenerated {
                    Image(systemName: "doc.text.fill").font(.system(size: 13)).foregroundStyle(Color(hexv: 0x9fd9ad))
                    Text(doc.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hexv: 0xecd9c9)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { state.openGenerated() } label: { genPill("Ouvrir") }.buttonStyle(.plain)
                    Button { state.revealGenerated() } label: { genPill("Révéler") }.buttonStyle(.plain)
                    Button { state.lastGenerated = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(hexv: 0x8a7d75)).frame(width: 20, height: 20)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 13)
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color(hexv: 0x5fd07a).opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color(hexv: 0x5fd07a).opacity(0.22), lineWidth: 1))
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

    @ViewBuilder private var transcript: some View {
        if state.herConversation.isEmpty {
            Text("Dis « Bonjour » ou pose-moi une question — je te réponds à voix haute. Confie-moi une tâche (« liste mes fichiers ») et tu verras le travail se dérouler ici, sous ta demande.")
                .font(.system(size: 12.5)).foregroundStyle(Color.emberMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440).frame(maxHeight: .infinity, alignment: .center)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("— L'ÉCHANGE —").font(.system(size: 10, weight: .medium)).tracking(1.4)
                            .foregroundStyle(Color(hexv: 0x8a7a70)).frame(maxWidth: .infinity, alignment: .center)
                        ForEach(state.herConversation) { turn in
                            bubble(turn)
                            if turn.working { WorkInline(expanded: $workExpanded) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: state.herConversation) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: state.agentEvents) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }

    private func bubble(_ turn: HerTurn) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if turn.role == .user { Spacer(minLength: 60) }
            VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 3) {
                Text(turn.role == .user ? "TOI" : "EMBER")
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
            .buttonStyle(.plain).help(state.voiceSession ? "Couper la conversation" : "Conversation vocale (mains libres)")

            TextField(speech.listening ? (liveText.isEmpty ? "À l'écoute…" : liveText)
                       : (state.voiceSession ? "En conversation — appuie pour couper" : "Parle ou écris à Ember…"), text: $draft)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.emberInk)
                .onSubmit { if canSend { send() } }

            // 📄 générer un VRAI document local à partir du brief
            Button(action: generateDoc) {
                Image(systemName: state.generating ? "doc.badge.gearshape" : "doc.badge.plus")
                    .font(.system(size: 17)).foregroundStyle(Color(hexv: 0xc79a82))
            }
            .buttonStyle(.plain)
            .disabled(state.generating || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Générer un document (local)")

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
            Text(state.voiceSession && speech.fullDuplex ? "Voix 100% locale · duplex" : "Voix & conversation 100% locales")
                .font(.system(size: 11)).foregroundStyle(Color(hexv: 0x9bbfa3))
            Spacer(minLength: 6)
            Button { state.fullDuplexWanted.toggle() } label: {
                pill(on: state.fullDuplexWanted, icon: "waveform", label: state.fullDuplexWanted ? "Duplex ON" : "Duplex")
            }
            .buttonStyle(.plain)
            .help("Te couper la parole en parlant (annulation d'écho). Expérimental — au casque c'est idéal.")
            Button { state.trustMode.toggle() } label: {
                pill(on: state.trustMode, icon: state.trustMode ? "bolt.shield.fill" : "bolt.shield",
                     label: state.trustMode ? "Confiance ON" : "Confiance")
            }
            .buttonStyle(.plain)
            .help("Auto-autoriser les actions non sensibles cette session (l'envoi/suppression reste toujours confirmé)")
        }
    }

    private func pill(on: Bool, icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon); Text(label)
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

    var body: some View {
        if !state.agentEvents.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(Color(hexv: 0xffa050).opacity(0.5)).frame(width: 2)
                VStack(alignment: .leading, spacing: 8) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: state.agentBusy ? "gearshape.2" : "checkmark.seal").font(.system(size: 12))
                                .foregroundStyle(Color(hexv: 0xffa050))
                            Text("Travail · \(steps) étape\(steps > 1 ? "s" : "")")
                                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color(hexv: 0xffa050))
                            Spacer()
                            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 11))
                                .foregroundStyle(Color(hexv: 0x8a7a70))
                            Text(open ? "replier" : "dérouler").font(.system(size: 11)).foregroundStyle(Color(hexv: 0x8a7a70))
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
                    }
                }
                .padding(.leading, 11)
                Spacer(minLength: 40)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Synthetic overview (à côté, quand le travail est conséquent)

private struct OverviewCard: View {
    @EnvironmentObject var state: AppState

    private var done: Int { state.agentEvents.filter { $0.type == "observation" }.count }
    private var planned: Int { max(done, state.agentEvents.filter { $0.type == "tool" }.count) }
    private var tools: [AgentEvent] { state.agentEvents.filter { $0.type == "tool" } }
    private var status: (String, Color) {
        if state.agentPendingGate != nil { return ("Permission requise", Color(hexv: 0xffd089)) }
        if state.agentBusy { return ("En cours…", Color(hexv: 0xffa050)) }
        return ("Terminé", Color(hexv: 0x7fd095))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.3.group").font(.system(size: 12)).foregroundStyle(Color(hexv: 0xc79a82))
                Text("Vue d'ensemble").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(hexv: 0xf0ddcf))
                Spacer()
            }
            HStack(spacing: 8) {
                Circle().fill(status.1).frame(width: 7, height: 7)
                Text(status.0).font(.system(size: 12, weight: .medium)).foregroundStyle(status.1)
                Spacer()
                Text("\(done)/\(max(planned, 1)) étapes").font(.system(size: 11)).foregroundStyle(Color.emberMuted)
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if tools.isEmpty {
                Text("La synthèse des étapes s'affiche ici dès qu'Ember agit.")
                    .font(.system(size: 11)).foregroundStyle(Color.emberMuted).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { idx, e in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: idx < done ? "checkmark.circle.fill" : "circle.dotted")
                                .font(.system(size: 12)).foregroundStyle(idx < done ? Color(hexv: 0x7fd095) : Color(hexv: 0x9a8d84))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.label(e.tool)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(hexv: 0xe8d4c6))
                                if !e.detail.isEmpty {
                                    Text(e.detail).font(.system(size: 10.5)).foregroundStyle(Color.emberMuted).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "cloud").font(.system(size: 11)).foregroundStyle(Color(hexv: 0xc9a98f))
                // Honnêteté §2.4 : l'agent de travail tourne sur DeepSeek — le plan ET les
                // résultats d'outils y transitent (≠ 100% local, contrairement à la conversation).
                Text("Travail piloté par DeepSeek (cloud) · le plan et les résultats y transitent")
                    .font(.system(size: 10)).foregroundStyle(Color(hexv: 0xc9a98f))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18).frame(maxHeight: 440, alignment: .top).glassCard(corner: 20)
    }

    static func label(_ tool: String) -> String {
        switch tool {
        case "list_facts":       return "Mémoire"
        case "search_memory":    return "Recherche mémoire"
        case "list_dir":         return "Dossier"
        case "read_file":        return "Lecture fichier"
        case "write_note":       return "Note / brouillon"
        case "open_app":         return "App"
        case "open_url":         return "Lien"
        case "reveal_in_finder": return "Finder"
        case "spotlight_search": return "Recherche fichiers"
        case "search_text":      return "Recherche texte"
        case "read_clipboard":   return "Presse-papiers"
        case "notify":           return "Notification"
        case "read_notes":       return "Notes"
        case "read_reminders":   return "Rappels"
        case "read_calendar":    return "Agenda"
        case "write_clipboard":  return "Presse-papiers"
        case "create_note":      return "Note"
        case "create_reminder":  return "Rappel"
        case "create_event":     return "Événement"
        case "move_file":        return "Déplacement"
        case "copy_file":        return "Copie"
        case "music_control":    return "Musique"
        case "draft_mail":       return "Brouillon mail"
        case "run_shortcut":     return "Raccourci"
        default:                 return tool.isEmpty ? "Étape" : tool
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
        case "error":              stepRow(icon: "exclamationmark.triangle.fill", tint: Color(hexv: 0xff6b5a), title: "Erreur", detail: event.text)
        case "tool":               stepRow(icon: toolIcon, tint: Color(hexv: 0xffa050), title: toolTitle, detail: event.detail)
        case "observation":        stepRow(icon: event.denied ? "xmark.circle.fill" : "checkmark.circle.fill",
                                            tint: event.denied ? Color(hexv: 0xff6b5a) : Color(hexv: 0x7fd095),
                                            title: nil, detail: event.text)
        case "plan":               stepRow(icon: "target", tint: Color(hexv: 0xc79a82), title: "Tâche", detail: event.text)
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
        case "list_facts":      return "Consulte la mémoire"
        case "search_memory":   return "Cherche dans la mémoire"
        case "list_dir":        return "Liste un dossier"
        case "read_file":       return "Lit un fichier"
        case "write_note":      return "Écrit une note"
        case "open_app":        return "Ouvre une app"
        case "open_url":        return "Ouvre un lien"
        case "reveal_in_finder": return "Montre dans le Finder"
        case "spotlight_search": return "Cherche des fichiers"
        case "search_text":     return "Cherche du texte"
        case "read_clipboard":  return "Lit le presse-papiers"
        case "notify":          return "Notifie"
        case "read_notes":      return "Lit tes notes"
        case "read_reminders":  return "Lit tes rappels"
        case "read_calendar":   return "Lit ton agenda"
        case "write_clipboard": return "Copie dans le presse-papiers"
        case "create_note":     return "Crée une note"
        case "create_reminder": return "Crée un rappel"
        case "create_event":    return "Crée un événement"
        case "move_file":       return "Déplace un fichier"
        case "copy_file":       return "Copie un fichier"
        case "music_control":   return "Contrôle la musique"
        case "draft_mail":      return "Prépare un brouillon de mail"
        case "run_shortcut":    return "Lance un raccourci"
        default:                return event.tool
        }
    }

    private func stepRow(icon: String, tint: Color, title: String?, detail: String) -> some View {
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

    private var gateDesc: String {
        switch event.tool {
        case "__cloud__":        return "Envoyer ta demande — et les résultats des outils (fichiers, notes, mémoire lus) — à DeepSeek (cloud) pour cette tâche. Rien n'est encore sorti."
        case "list_facts":       return "Lire tes faits de mémoire personnelle"
        case "search_memory":    return "Chercher dans ta mémoire personnelle"
        case "write_note":       return "Écrire « \(event.detail) » dans tes brouillons"
        case "read_file":        return "Lire « \(event.detail) »"
        case "list_dir":         return "Lister « \(event.detail) »"
        case "open_app":         return "Ouvrir l'app « \(event.detail) »"
        case "open_url":         return "Ouvrir le lien « \(event.detail) »"
        case "reveal_in_finder": return "Montrer « \(event.detail) » dans le Finder"
        case "spotlight_search": return "Chercher « \(event.detail) » sur le Mac"
        case "search_text":      return "Chercher du texte dans « \(event.detail) »"
        case "read_notes":       return "Lire tes notes"
        case "read_reminders":   return "Lire tes rappels"
        case "read_calendar":    return "Lire ton agenda du jour"
        case "write_clipboard":  return "Copier du texte dans le presse-papiers"
        case "create_note":      return "Créer la note « \(event.detail) »"
        case "create_reminder":  return "Créer le rappel « \(event.detail) »"
        case "create_event":     return "Créer l'événement « \(event.detail) »"
        case "move_file":        return "Déplacer « \(event.detail) »"
        case "copy_file":        return "Copier un fichier"
        case "music_control":    return "Contrôler la musique (\(event.detail))"
        case "draft_mail":       return "Préparer un brouillon de mail « \(event.detail) » (non envoyé)"
        case "run_shortcut":     return "Lancer le raccourci « \(event.detail) »"
        default:                 return event.tool
        }
    }

    // Tools whose RESULT (content read) is sent to the cloud brain → warn before consenting.
    private var cloudWarn: String? {
        let exfil: Set<String> = ["read_file", "list_dir", "read_notes", "read_reminders",
                                  "read_calendar", "spotlight_search", "search_text",
                                  "read_clipboard", "list_facts", "search_memory"]
        return exfil.contains(event.tool) ? "Le contenu lu sera envoyé à DeepSeek (cloud)." : nil
    }

    // Tier-3 scopes always re-ask (no "Toujours"): the cloud egress, shortcuts, sends, deletes…
    private var isTier3: Bool {
        ["Cloud (DeepSeek)", "Raccourcis", "Mail-envoi", "Messages-envoi",
         "Agenda-invitation", "Fichiers-suppr", "Écran"].contains(event.scope)
    }

    private var gateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 12.5)).foregroundStyle(Color(hexv: 0xffd089)).frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Permission : \(event.scope)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hexv: 0xffd089))
                    Text(gateDesc).font(.system(size: 11)).foregroundStyle(Color.emberMuted).fixedSize(horizontal: false, vertical: true)
                    if let warn = cloudWarn {
                        HStack(spacing: 5) {
                            Image(systemName: "cloud.fill").font(.system(size: 9))
                            Text(warn).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 10)).foregroundStyle(Color(hexv: 0xff9a5a)).padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button(action: onAllow)  { gateLabel("Autoriser", fill: true) }.buttonStyle(.plain)
                if !isTier3 {
                    Button(action: onAlways) { gateLabel("Toujours", fill: false) }.buttonStyle(.plain)
                }
                Button(action: onDeny)   { gateLabel("Refuser", fill: false) }.buttonStyle(.plain)
            }
            .padding(.leading, 27)
            Text(isTier3
                 ? "Action sensible — Ember te redemandera à chaque fois (pas de « toujours »). Tu peux répondre « oui » / « non » à voix haute."
                 : "« Toujours » = ne plus redemander pour CE chemin cette session. Tu peux aussi répondre « oui » / « non » à voix haute.")
                .font(.system(size: 10)).foregroundStyle(Color(hexv: 0x8a7a70))
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 27)
        }
        .padding(.vertical, 8).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hexv: 0xffc850).opacity(0.08)))
    }

    private func gateLabel(_ t: String, fill: Bool) -> some View {
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
