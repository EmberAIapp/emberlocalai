import SwiftUI

/// Mode Her — mains-libres, conversation fluide (style ChatGPT) + DEUX FLUX SÉPARÉS :
///   • carte CONVERSATION : on parle à Ember, elle répond (chat local) et parle (voix Kokoro).
///   • carte TRAVAIL      : l'agent (DeepSeek + permissions) quand une vraie tâche est détectée.
/// Visuel calme : petite orbe + signal sinusoïdal animé dans la couleur Ember (au lieu d'une
/// grosse orbe intimidante). La voix d'Ember suit la langue du système.
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
                center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 900)
            .ignoresSafeArea()
            centerContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { topBar }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            speech.requestAuth()
            speech.onTranscript = { t in
                // « stop » / « arrête » between turns ends the continuous voice session.
                if state.voiceSession && state.isStopPhrase(t) { state.voiceSession = false; speech.stopSpeaking() }
                else { state.herSend(t) }
            }
        }
        .onChange(of: speech.listening) { _, v in state.herListening = v }
        .onChange(of: speech.speaking)  { _, v in
            state.herSpeaking = v
            // Turn-based only: reopen the mic after she speaks. Full-duplex self-manages its loop
            // (the mic never closed) so the view must NOT also reopen it.
            if state.voiceSession && !v && !speech.fullDuplex { reopenMic() }
        }
        .onChange(of: state.herSpeak) { _, req in
            guard let req else { return }
            Task {
                // Speak the reply; the loop reopens the mic only AFTER `speaking` goes false.
                // Never reopen earlier — the mic must not be open while Ember talks (it would
                // hear herself). This race was why the continuous loop misbehaved.
                if !req.text.isEmpty, let data = await state.ttsData(req.text, req.lang) {
                    speech.playWav(data)
                } else if !req.text.isEmpty {
                    speech.speakFallback(req.text, locale: SpeechController.locale(for: req.lang))
                } else if state.voiceSession {
                    reopenMic()
                }
            }
        }
        .onDisappear { speech.endVoice() }
    }

    private func micLocale() -> String { SpeechController.locale(for: state.herLang) }
    private func startVoice() { state.voiceSession = true; speech.startVoice(locale: micLocale()) }
    private func endVoice() { state.voiceSession = false; speech.endVoice() }
    private func toggleVoice() { if state.voiceSession { endVoice() } else { startVoice() } }
    /// Continuous mode: a moment after Ember stops speaking, reopen the mic for the next turn.
    private func reopenMic() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if state.voiceSession, !speech.listening, !speech.speaking, !state.isBusy, !state.agentBusy {
                speech.toggleListening(locale: micLocale())
            }
        }
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 10) {
                Circle().fill(Color(hexv: 0xff7a3a)).frame(width: 7, height: 7)
                    .shadow(color: Color(hexv: 0xff7a3a), radius: 5)
                    .scaleEffect(pulse ? 1.3 : 0.9).opacity(pulse ? 1.0 : 0.5)
                Text("MODE HER · MAINS LIBRES").font(.system(size: 12, weight: .bold)).tracking(1)
                    .foregroundStyle(Color(hexv: 0xc79a82))
            }
            Spacer()
            Button(action: { speech.stopSpeaking(); state.exitHer() }) {
                Text("Quitter ✕").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xd8c6ba))
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 22).padding(.horizontal, 30)
    }

    private var centerContent: some View {
        HStack(alignment: .top, spacing: 48) {
            HerLeftColumn(speech: speech).frame(maxWidth: .infinity)
            VStack(spacing: 16) {
                ConversationCard(speech: speech, onMic: toggleVoice)
                if !state.agentEvents.isEmpty { WorkCard() }       // flux TRAVAIL, carte séparée
            }
            .frame(width: 460)
        }
        .padding(.horizontal, 52).padding(.top, 96).padding(.bottom, 40)
    }
}

// MARK: - Left column: small orb + themed sine signal + live caption

private struct HerLeftColumn: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var speech: SpeechController

    private var caption: String {
        if speech.listening { return speech.partial.isEmpty ? "À l'écoute…" : speech.partial }
        if state.agentBusy, let last = state.agentEvents.last(where: { ["plan","tool","observation"].contains($0.type) }) {
            return last.text.isEmpty ? "Je m'en occupe…" : last.text
        }
        if let last = state.herConversation.last(where: { $0.role == .ember && !$0.text.isEmpty }) { return last.text }
        return state.voiceSession ? "Je t'écoute — parle quand tu veux." : "Parle-moi, ou confie-moi une tâche."
    }

    private var level: CGFloat {
        if speech.listening { return 0.9 }
        if state.herSpeaking { return 0.6 }
        if state.agentBusy || state.isBusy { return 0.32 }
        return 0.14
    }

    var body: some View {
        VStack(spacing: 26) {
            EmberOrb(mode: state.orbMode, size: 96).frame(width: 96, height: 96)   // petite — moins intimidante
            VoiceWave(level: level).frame(width: 380, height: 88)
            Text(caption)
                .font(.emberSerif(20, weight: .regular).italic())
                .foregroundStyle(Color(hexv: 0xd8b9a6))
                .multilineTextAlignment(.center).lineSpacing(20 * 0.4)
                .frame(maxWidth: 400).padding(.top, 4)
                .animation(.easeInOut(duration: 0.3), value: caption)
        }
        .padding(.top, 30)
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
                        let env = sin(rel * .pi)                                  // taper at both ends
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

// MARK: - Flux CONVERSATION (carte) — bulles + saisie voix/texte

private struct ConversationCard: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var speech: SpeechController
    var onMic: () -> Void
    @State private var draft = ""

    private var canSend: Bool { !state.agentBusy && !draft.trimmingCharacters(in: .whitespaces).isEmpty }
    private func send() { let t = draft; draft = ""; state.herSend(t) }

    private var placeholder: String {
        if speech.listening { return speech.partial.isEmpty ? "À l'écoute…" : speech.partial }
        if state.voiceSession { return "En conversation — appuie pour couper" }
        return "Parle ou écris à Ember…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation").font(.system(size: 13, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Color(hexv: 0xf0ddcf))
                Spacer()
                Text(state.voiceSession ? (speech.fullDuplex ? "mains libres · duplex" : "mains libres") : "local")
                    .font(.system(size: 11)).foregroundStyle(speech.fullDuplex && state.voiceSession ? Color(hexv: 0x7fd095) : Color.emberMuted)
                    .padding(.vertical, 3).padding(.horizontal, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
            }
            transcript
            input
            footer
        }
        .padding(22).glassCard(corner: 22)
    }

    @ViewBuilder private var transcript: some View {
        if state.herConversation.isEmpty {
            Text("Dis « Bonjour » ou pose-moi une question — je te réponds à voix haute. Confie-moi une tâche (« liste mes fichiers ») et je passe en mode travail, dans la carte du dessous.")
                .font(.system(size: 12)).foregroundStyle(Color.emberMuted)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.herConversation) { turn in bubble(turn) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: state.herConversation) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }

    private func bubble(_ turn: HerTurn) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if turn.role == .user { Spacer(minLength: 48) }
            Group {
                if turn.role == .ember {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Color(hexv: 0xff9a4a)).frame(width: 16)
                        Text(turn.text.isEmpty ? "…" : turn.text)
                            .font(.emberSerif(15, weight: .regular)).foregroundStyle(Color(hexv: 0xf0ddcf))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color(hexv: 0xff783c).opacity(0.08)))
                } else {
                    Text(turn.text)
                        .font(.system(size: 13)).foregroundStyle(Color(hexv: 0xe8d4c6))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.05)))
                }
            }
            if turn.role == .ember { Spacer(minLength: 48) }
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

            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.emberInk)
                .onSubmit { if canSend { send() } }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundStyle(canSend ? Color(hexv: 0xff7a3a) : Color.white.opacity(0.2))
            }
            .buttonStyle(.plain).disabled(!canSend)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hexv: 0xff965a).opacity(0.25), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Color(hexv: 0x7fd095))
            // Honnêteté §2.4 : voix & conversation 100% locales ; l'agent de travail = DeepSeek (cloud).
            Text("Voix & conversation 100% locales")
                .font(.system(size: 11)).foregroundStyle(Color(hexv: 0x9bbfa3))
        }
    }
}

// MARK: - Flux TRAVAIL (carte séparée) — l'agent : étapes live + permissions

private struct WorkCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "gearshape.2").font(.system(size: 11)).foregroundStyle(Color(hexv: 0xffa050))
                Text("Travail").font(.system(size: 13, weight: .bold)).tracking(0.5).foregroundStyle(Color(hexv: 0xf0ddcf))
                Spacer()
                Text(state.agentBusy ? "en cours · DeepSeek" : "agent · DeepSeek")
                    .font(.system(size: 11)).foregroundStyle(Color.emberMuted)
                    .padding(.vertical, 3).padding(.horizontal, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.agentEvents) { e in
                        HerEventRow(event: e,
                                    onAllow: { state.resolveAgentGate(true) },
                                    onDeny: { state.resolveAgentGate(false) })
                    }
                }
            }
            .frame(maxHeight: 240)
            HStack(spacing: 9) {
                Image(systemName: "lock.shield").font(.system(size: 12)).foregroundStyle(Color(hexv: 0x9bbfa3))
                Text("Rien sans ta permission · cloud (DeepSeek)")
                    .font(.system(size: 11)).foregroundStyle(Color(hexv: 0x9bbfa3))
            }
        }
        .padding(22).glassCard(corner: 22)
    }
}

// MARK: - One agent event row (work stream)

private struct HerEventRow: View {
    let event: AgentEvent
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        switch event.type {
        case "gate":               gateRow
        case "done", "message":    EmptyView()   // le résumé apparaît comme bulle Ember dans la conversation
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
        case "read_file", "list_dir":        return "folder"
        case "write_note":                   return "square.and.pencil"
        default:                             return "gearshape"
        }
    }
    private var toolTitle: String {
        switch event.tool {
        case "list_facts":     return "Consulte la mémoire"
        case "search_memory":  return "Cherche dans la mémoire"
        case "list_dir":       return "Liste un dossier"
        case "read_file":      return "Lit un fichier"
        case "write_note":     return "Écrit une note"
        default:               return event.tool
        }
    }

    private func stepRow(icon: String, tint: Color, title: String?, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if let title { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hexv: 0xe8d4c6)) }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color.emberMuted)
                        .lineLimit(title == nil ? 4 : 2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 9).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gateDesc: String {
        switch event.tool {
        case "write_note": return "Écrire « \(event.detail) » dans tes brouillons"
        case "read_file":  return "Lire « \(event.detail) »"
        case "list_dir":   return "Lister « \(event.detail) »"
        default:           return event.tool
        }
    }

    private var gateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 13)).foregroundStyle(Color(hexv: 0xffd089)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Permission : \(event.scope)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hexv: 0xffd089))
                    Text(gateDesc).font(.system(size: 11)).foregroundStyle(Color.emberMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button(action: onAllow) { gateLabel("Autoriser", fill: true) }.buttonStyle(.plain)
                Button(action: onDeny)  { gateLabel("Refuser", fill: false) }.buttonStyle(.plain)
            }
            .padding(.leading, 28)
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
