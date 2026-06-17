import SwiftUI

/// Mode Her — mains-libres, TWO FLOWS (§4.E):
///   • flux CONVERSATION : on parle à Ember, elle répond (chat local) et parle (voix Kokoro).
///   • flux TRAVAIL     : quand elle détecte une vraie tâche, l'agent (DeepSeek + permissions)
///     s'exécute — et la conversation reste visible au-dessus.
/// La voix d'Ember suit la langue du système.
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
            speech.onTranscript = { t in state.herSend(t) }   // voix → conversation/travail
        }
        .onChange(of: speech.listening) { _, v in state.herListening = v }
        .onChange(of: speech.speaking)  { _, v in state.herSpeaking = v }
        .onChange(of: state.herSpeak) { _, req in
            guard let req, !req.text.isEmpty else { return }
            Task {
                if let data = await state.ttsData(req.text, req.lang) { speech.playWav(data) }
                else { speech.speakFallback(req.text, locale: SpeechController.locale(for: req.lang)) }
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
        HStack(spacing: 56) {
            HerLeftColumn(speech: speech)
            HerPanel(speech: speech).frame(width: 460)
        }
        .padding(.horizontal, 56)
    }
}

// MARK: - Orb + voice column (caption shows the LIVE transcript while you speak)

private struct HerLeftColumn: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var speech: SpeechController

    private var caption: String {
        if speech.listening { return speech.partial.isEmpty ? "À l'écoute…" : speech.partial }
        if state.agentBusy, let last = state.agentEvents.last(where: { ["plan","tool","observation"].contains($0.type) }) {
            return last.text.isEmpty ? "Je m'en occupe…" : last.text
        }
        if let last = state.herConversation.last(where: { $0.role == .ember && !$0.text.isEmpty }) { return last.text }
        return "Parle-moi, ou confie-moi une tâche."
    }

    var body: some View {
        VStack(spacing: 0) {
            EmberOrb(mode: state.orbMode, size: 240).frame(width: 240, height: 240)
            HerWaveform(active: speech.listening || state.herSpeaking).padding(.top, 34)
            Text(caption)
                .font(.emberSerif(21, weight: .regular).italic())
                .foregroundStyle(Color(hexv: 0xd8b9a6))
                .multilineTextAlignment(.center).lineSpacing(21 * 0.4)
                .frame(maxWidth: 380).padding(.top, 24)
                .animation(.easeInOut(duration: 0.3), value: caption)
        }
    }
}

// MARK: - Waveform — 11 bars, animated only while listening/speaking

private struct HerWaveform: View {
    var active: Bool = true
    @State private var animate = false
    private let count = 11

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(hexv: 0xffb877), Color(hexv: 0xff6024)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 5, height: 40)
                    .scaleEffect(y: (animate && active) ? 1.0 : 0.22, anchor: .bottom)
                    .animation(.easeInOut(duration: 0.7 + Double(i % 4) * 0.18)
                        .repeatForever(autoreverses: true).delay(Double(i) * 0.08), value: animate)
                    .opacity(active ? 1 : 0.4)
            }
        }
        .frame(height: 40).onAppear { animate = true }
    }
}

// MARK: - The two-flow panel: conversation (top) + work stream (below) + voice/text input

private struct HerPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var speech: SpeechController
    @State private var draft = ""

    private var canSend: Bool { !state.agentBusy && !draft.trimmingCharacters(in: .whitespaces).isEmpty }
    private func send() {
        let t = draft; draft = ""
        state.herSend(t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 12)
            timeline
            input.padding(.top, 12)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 12)
            footer.padding(.top, 10)
        }
        .padding(24)
        .glassCard(corner: 22)
    }

    private var header: some View {
        HStack {
            Text("Ember, en direct").font(.system(size: 13, weight: .bold)).tracking(0.5)
                .foregroundStyle(Color(hexv: 0xf0ddcf))
            Spacer()
            Text(state.agentBusy ? "travail · DeepSeek" : "conversation · local")
                .font(.system(size: 11)).foregroundStyle(Color.emberMuted)
                .padding(.vertical, 3).padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        }
    }

    @ViewBuilder private var timeline: some View {
        if state.herConversation.isEmpty && state.agentEvents.isEmpty {
            Text("Dis « Bonjour » ou pose-moi une question — je te réponds à voix haute. Et si tu me confies une tâche (« liste mes fichiers », « écris un brouillon de mail »), je passe en mode travail et je te demande la permission pour toute action sensible.")
                .font(.system(size: 12)).foregroundStyle(Color.emberMuted)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 14)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // FLUX CONVERSATION
                        ForEach(state.herConversation) { turn in bubble(turn) }
                        // FLUX TRAVAIL — visible sous la conversation pendant l'exécution
                        if !state.agentEvents.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape.2").font(.system(size: 10))
                                Text("TRAVAIL").font(.system(size: 10, weight: .bold)).tracking(1.5)
                            }
                            .foregroundStyle(Color(hexv: 0xc79a82)).padding(.top, 6).padding(.leading, 2)
                            ForEach(state.agentEvents) { e in
                                HerEventRow(event: e,
                                            onAllow: { state.resolveAgentGate(true) },
                                            onDeny: { state.resolveAgentGate(false) })
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .frame(maxHeight: 320)
                .onChange(of: state.herConversation) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: state.agentEvents) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
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
            Button(action: { speech.toggleListening(locale: SpeechController.locale(for: state.herLang)) }) {
                Image(systemName: speech.listening ? "mic.fill" : "mic").font(.system(size: 17))
                    .foregroundStyle(speech.listening ? Color(hexv: 0xff5a46) : Color(hexv: 0x9a8d84))
            }
            .buttonStyle(.plain).help(speech.listening ? "Arrêter l'écoute" : "Parler à Ember")

            TextField(speech.listening ? (speech.partial.isEmpty ? "À l'écoute…" : speech.partial)
                                       : "Parle ou écris à Ember…", text: $draft)
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
            Image(systemName: "checkmark.shield").font(.system(size: 13)).foregroundStyle(Color(hexv: 0x7fd095))
            // Honesty (§2.4): conversation + voice are 100% local; the work-agent brain is DeepSeek (cloud).
            Text("Voix & conversation 100% locales · agent de travail via DeepSeek (cloud), rien sans ta permission")
                .font(.system(size: 11)).foregroundStyle(Color(hexv: 0x9bbfa3))
                .fixedSize(horizontal: false, vertical: true)
        }
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
        case "done", "message":    EmptyView()   // summary is shown as an Ember conversation bubble
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
