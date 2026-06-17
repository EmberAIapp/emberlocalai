import SwiftUI

struct HerView: View {
    @EnvironmentObject var state: AppState
    @State private var pulse = false

    var body: some View {
        ZStack {
            // background:radial-gradient(120% 100% at 50% 35%,#2a1812 0%,#130b08 60%,#080404 100%)
            RadialGradient(
                stops: [
                    .init(color: Color(hexv: 0x2a1812), location: 0),
                    .init(color: Color(hexv: 0x130b08), location: 0.6),
                    .init(color: Color(hexv: 0x080404), location: 1)
                ],
                center: UnitPoint(x: 0.5, y: 0.35),
                startRadius: 0,
                endRadius: 900
            )
            .ignoresSafeArea()

            centerContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { topBar }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hexv: 0xff7a3a))
                    .frame(width: 7, height: 7)
                    .shadow(color: Color(hexv: 0xff7a3a), radius: 5)
                    .scaleEffect(pulse ? 1.3 : 0.9)
                    .opacity(pulse ? 1.0 : 0.5)
                Text("MODE HER · MAINS LIBRES")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Color(hexv: 0xc79a82))
            }
            Spacer()
            Button(action: { state.exitHer() }) {
                Text("Quitter ✕")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xd8c6ba))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 22)
        .padding(.horizontal, 30)
    }

    private var centerContent: some View {
        HStack(spacing: 64) {
            HerLeftColumn()
            HerAgentPanel()
                .frame(width: 440)
        }
        .padding(.horizontal, 60)
    }
}

// MARK: - Orb + voice column

private struct HerLeftColumn: View {
    @EnvironmentObject var state: AppState

    // The orb's caption: the agent's latest line if it's working, else the ambient transcript.
    private var caption: String {
        if let last = state.agentEvents.last(where: { ["done", "message", "plan"].contains($0.type) }) {
            return last.text
        }
        return DesignData.herTranscript
    }

    var body: some View {
        VStack(spacing: 0) {
            EmberOrb(mode: state.orbMode, size: 240)
                .frame(width: 240, height: 240)

            HerWaveform()
                .padding(.top, 34)

            Text(caption)
                .font(.emberSerif(21, weight: .regular).italic())
                .foregroundStyle(Color(hexv: 0xd8b9a6))
                .multilineTextAlignment(.center)
                .lineSpacing(21 * 0.4)
                .frame(maxWidth: 380)
                .padding(.top, 24)
                .animation(.easeInOut(duration: 0.3), value: caption)
        }
    }
}

// MARK: - Waveform — 11 bars, 5px×40px, gradient #ffb877→#ff6024, animated

private struct HerWaveform: View {
    @State private var animate = false
    private let count = 11

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(hexv: 0xffb877), Color(hexv: 0xff6024)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 5, height: 40)
                    .scaleEffect(y: animate ? 1.0 : 0.25, anchor: .bottom)
                    .animation(.easeInOut(duration: 0.7 + Double(i % 4) * 0.18)
                        .repeatForever(autoreverses: true).delay(Double(i) * 0.08), value: animate)
            }
        }
        .frame(height: 40)
        .onAppear { animate = true }
    }
}

// MARK: - Agent panel — REAL agent (DeepSeek brain + local tools), live + permission gates

private struct HerAgentPanel: View {
    @EnvironmentObject var state: AppState
    @State private var task = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 14)
            taskInput.padding(.bottom, 14)
            eventsList
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 14)
            footer.padding(.top, 12)
        }
        .padding(24)
        .glassCard(corner: 22)
    }

    private var header: some View {
        HStack {
            Text("Agents au travail")
                .font(.system(size: 13, weight: .bold)).tracking(0.5)
                .foregroundStyle(Color(hexv: 0xf0ddcf))
            Spacer()
            Text(state.agentBusy ? "en cours…" : "cerveau DeepSeek")
                .font(.system(size: 11)).foregroundStyle(Color.emberMuted)
                .padding(.vertical, 3).padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        }
    }

    private var canRun: Bool { !state.agentBusy && !task.trimmingCharacters(in: .whitespaces).isEmpty }
    private func run() { guard canRun else { return }; let t = task; task = ""; state.runAgentTask(t) }

    private var taskInput: some View {
        HStack(spacing: 8) {
            TextField("Confie une tâche à Ember…", text: $task)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.emberInk)
                .onSubmit(run)
            Button(action: run) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundStyle(canRun ? Color(hexv: 0xff7a3a) : Color.white.opacity(0.2))
            }
            .buttonStyle(.plain).disabled(!canRun)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hexv: 0xff965a).opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder private var eventsList: some View {
        if state.agentEvents.isEmpty {
            Text("Donne-lui une vraie tâche : « récapitule ce que tu sais de moi », « résume ce fichier », « prépare un brouillon de mail »… Elle planifie, agit, et te demande la permission pour toute action sensible.")
                .font(.system(size: 12)).foregroundStyle(Color.emberMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.agentEvents) { e in
                        HerEventRow(event: e,
                                    onAllow: { state.resolveAgentGate(true) },
                                    onDeny: { state.resolveAgentGate(false) })
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.shield").font(.system(size: 13)).foregroundStyle(Color(hexv: 0x7fd095))
            // Honesty (§2.4): the agent brain is DeepSeek (cloud), not local.
            Text("Rien sans ta permission · agent via DeepSeek (cloud)")
                .font(.system(size: 11)).foregroundStyle(Color(hexv: 0x9bbfa3))
        }
    }
}

// MARK: - One agent event row

private struct HerEventRow: View {
    let event: AgentEvent
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        switch event.type {
        case "gate":               gateRow
        case "done", "message":    summaryRow
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
        .padding(.vertical, 6).padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Color(hexv: 0xff9a4a)).frame(width: 18)
            Text(event.text).font(.emberSerif(15, weight: .regular)).foregroundStyle(Color(hexv: 0xf0ddcf))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hexv: 0xff783c).opacity(0.08)))
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
