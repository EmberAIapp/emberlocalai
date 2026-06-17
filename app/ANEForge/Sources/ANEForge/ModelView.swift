import SwiftUI

/// Accueil / chat — the heart of Ember. Hero orb on top with the mode chips, the
/// conversation in Ember's serif "voice" below, suggestions + a generative input
/// bar at the foot.
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var draft = ""
    // Local visual selection of the orb mode (the chips). When Ember is actually
    // busy/learning/talking the real derived state.orbMode takes over.
    @State private var pickedMode: OrbMode = .repos

    /// The mode the hero orb shows: the real engine-derived state while it's doing
    /// something, otherwise the chip the user picked.
    private var heroMode: OrbMode {
        if state.isLearning || state.isBusy || state.talking { return state.orbMode }
        return pickedMode
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            chat
            inputArea
        }
    }

    // MARK: Hero  (padding:26px 0 14px; align center)

    private var hero: some View {
        VStack(spacing: 0) {
            // orb container — height:188px, centered, tap-to-talk (reserved for Mode Her)
            Button { /* tap-to-talk is reserved for Mode Her */ } label: {
                EmberOrb(mode: heroMode, size: 158).frame(height: 188)
            }
            .buttonStyle(.plain)
            .help("Parler / interrompre")

            // serif italic caption — margin-top:4px, size 16, #b09a8c, nowrap
            Text(heroMode.caption)
                .font(.emberSerif(16, weight: .regular).italic())
                .foregroundStyle(Color(hexv: 0xb09a8c))
                .lineLimit(1)
                .fixedSize()
                .padding(.top, 4)

            // mode chips — gap:8px, margin-top:16px, wrap, centered
            FlexWrap(spacing: 8, lineSpacing: 8) {
                ForEach(OrbMode.allCases, id: \.self) { mode in
                    ModeChip(mode: mode, active: heroMode == mode) { pickedMode = mode }
                }
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26).padding(.bottom, 14)
    }

    // MARK: Conversation  (padding:14px 16% 8px; gap:18px)

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if state.messages.isEmpty {
                        Text(state.selected == nil
                             ? "Choisis une IA en haut, ou crées-en une."
                             : "Demande-lui n'importe quoi sur toi, ou décris ce que tu veux générer.")
                            .font(.emberSerif(17, weight: .regular).italic())
                            .foregroundStyle(.emberMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                    ForEach(state.messages) { msg in
                        MessageRow(message: msg, avatarMode: heroMode).id(msg.id)
                    }
                    if state.isBusy { busyRow }
                }
                .padding(.top, 14).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ChatLayout.sidePadding)
            }
            .onChange(of: state.messages.count) {
                if let last = state.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    // busy: busyOrb 26, "Ember génère" serif italic 18 #b09a8c + 3 pulse dots
    private var busyRow: some View {
        HStack(spacing: 14) {
            EmberOrb(mode: .reflexion, size: 26).frame(width: 26, height: 26)
            HStack(spacing: 8) {
                Text("Ember génère").font(.emberSerif(18, weight: .regular).italic())
                    .foregroundStyle(Color(hexv: 0xb09a8c))
                BouncingDots()
            }
        }
    }

    // MARK: Input  (padding:8px 16% 22px)

    private var inputArea: some View {
        VStack(spacing: 0) {
            // suggestions — gap:8px, margin-bottom:11px, centered, wrap
            FlexWrap(spacing: 8, lineSpacing: 8) {
                ForEach(DesignData.homeSuggestions, id: \.self) { s in
                    SuggestionChip(label: s) { send(s) }
                }
            }
            .padding(.bottom, 11)

            // generative input bar — gap:14px, padding:9px 9px 9px 18px, radius:30
            HStack(spacing: 14) {
                // "+" affordance — 32x32 circle, size 21, #9a8073
                Button { state.go(.ingest) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 21))
                        .foregroundStyle(Color(hexv: 0x9a8073))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Apprendre des données")

                // input — size 14.5, color #f3e9e2, placeholder
                TextField("Demande à Ember, ou décris ce que tu veux générer…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color(hexv: 0xf3e9e2))
                    .onSubmit { send(draft) }

                // talkOrb 42 in a 46x46 hit area — "Générer"
                Button { send(draft) } label: {
                    EmberOrb(mode: heroMode, size: 42).frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .help("Générer")
                .disabled(state.isBusy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 18).padding(.trailing, 9).padding(.vertical, 9)
            .background(inputBarBackground)
        }
        .padding(.top, 8).padding(.bottom, 22)
        .padding(.horizontal, ChatLayout.sidePadding)
    }

    // background:rgba(255,255,255,0.05) blur(20) sat(160%); border rgba(255,170,120,0.18);
    // box-shadow inset 0 1px 0 rgba(255,255,255,0.08), 0 8px 24px -10px rgba(0,0,0,0.5)
    private var inputBarBackground: some View {
        let cap = Capsule(style: .continuous)
        return ZStack {
            cap.fill(.ultraThinMaterial.opacity(0.35))
            cap.fill(.white.opacity(0.05))
            cap.strokeBorder(Color(hexv: 0xffaa78).opacity(0.18), lineWidth: 1)
            cap.stroke(LinearGradient(colors: [.white.opacity(0.08), .clear],
                                      startPoint: .top, endPoint: .center), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !state.isBusy else { return }
        draft = ""
        Task { await state.send(t) }
    }
}

// MARK: - Layout constants

/// The chat column padding. Design uses `16%` horizontal padding against the
/// 1440-wide design canvas → ~230pt each side; we approximate with a percentage
/// of the available width via a fixed inset that matches the design at 1440.
private enum ChatLayout {
    // 16% of 1440 = 230.4
    static let sidePadding: CGFloat = 230
}

// MARK: - Mode chip (sets the local orb mode — visual selector)

/// One of the hero mode chips (Repos / Écoute / Réflexion / Réponse / Apprentissage).
/// font-size:12.5px; weight active?600:500; padding:7px 15px; radius:20.
/// active: text #1a0f0a on a glow gradient + glow border + lift; inactive: muted on faint glass.
struct ModeChip: View {
    let mode: OrbMode
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.label)
                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                .tracking(0.2)
                .foregroundStyle(active ? Color.emberDeep : Color(hexv: 0x9a8d84))
                .padding(.horizontal, 15).padding(.vertical, 7)
                .background {
                    if active {
                        Capsule().fill(LinearGradient(
                            colors: [mode.glow.opacity(0.95), mode.glow.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Capsule().strokeBorder(mode.glow.opacity(0.6), lineWidth: 1))
                    } else {
                        Capsule().fill(.white.opacity(0.04))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    }
                }
                .shadow(color: active ? mode.glow.opacity(0.6) : .clear, radius: 9, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Suggestion chip (foot)

/// ✦ {label} — font-size:12.5px weight:500 padding:7px 14px radius:18 color:#c9a78f,
/// bg rgba(255,255,255,0.04), border rgba(255,170,120,0.16).
struct SuggestionChip: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("✦ \(label)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color(hexv: 0xc9a78f))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(
                    Capsule().fill(.white.opacity(0.04))
                        .overlay(Capsule().strokeBorder(Color(hexv: 0xffaa78).opacity(0.16), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - One message row (user bubble / AI serif voice)

struct MessageRow: View {
    let message: ChatMessage
    var avatarMode: OrbMode = .repos

    // border-radius:18px 18px 5px 18px (top-left, top-right, bottom-right, bottom-left)
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                               bottomTrailingRadius: 5, topTrailingRadius: 18,
                               style: .continuous)
    }

    var body: some View {
        if message.role == .user {
            // justify-content:flex-end, max-width:78%
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 14.5)).lineSpacing(2)
                    .foregroundStyle(Color(hexv: 0xecdccf))
                    .padding(.horizontal, 18).padding(.vertical, 13)
                    .background(.ultraThinMaterial.opacity(0.5), in: bubbleShape)
                    .background(Color(hexv: 0xffa06e).opacity(0.10), in: bubbleShape)
                    .overlay(bubbleShape.strokeBorder(Color(hexv: 0xffaa78).opacity(0.16), lineWidth: 1))
                    .overlay(bubbleShape.stroke(LinearGradient(colors: [.white.opacity(0.08), .clear],
                                                               startPoint: .top, endPoint: .center), lineWidth: 1))
            }
        } else {
            // gap:14px, align flex-start, avatarOrb 26 (margin-top:4px), body max-width:84%
            HStack(alignment: .top, spacing: 14) {
                EmberOrb(mode: avatarMode, size: 26).frame(width: 26, height: 26).padding(.top, 4)
                SerifMarkdown(message.text)
                    .frame(maxWidth: 640, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Ember's serif voice (light Markdown → SwiftUI)

struct SerifMarkdown: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
    }

    private struct Block { let view: AnyView }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("### ") {
                out.append(Block(view: AnyView(heading(String(line.dropFirst(4)), 18))))
            } else if line.hasPrefix("## ") {
                out.append(Block(view: AnyView(heading(String(line.dropFirst(3)), 22))))
            } else if line.hasPrefix("# ") {
                out.append(Block(view: AnyView(heading(String(line.dropFirst(2)), 26))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(Block(view: AnyView(bullet(String(line.dropFirst(2))))))
            } else {
                out.append(Block(view: AnyView(paragraph(line))))
            }
        }
        if out.isEmpty { out.append(Block(view: AnyView(paragraph(text)))) }
        return out
    }

    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s) { return Text(attr) }
        return Text(s)
    }

    // paragraph — design: font-size:17px line-height:1.62 color:#efe2d7
    private func paragraph(_ s: String) -> some View {
        inline(s).font(.emberSerif(17, weight: .regular)).foregroundStyle(Color(hexv: 0xefe2d7))
            .lineSpacing(17 * 0.62).fixedSize(horizontal: false, vertical: true)
    }
    private func heading(_ s: String, _ size: CGFloat) -> some View {
        inline(s).font(.emberSerif(size)).foregroundStyle(Color(hexv: 0xf3e3d7))
            .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
    }
    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.emberSerif(17, weight: .regular)).foregroundStyle(.ember1)
            inline(s).font(.emberSerif(16.5, weight: .regular)).foregroundStyle(Color(hexv: 0xe7d8cb))
                .lineSpacing(16.5 * 0.55).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Small helpers

/// A simple wrapping flow layout — keeps chips centered and wrapping like the design's
/// `flex-wrap:wrap; justify-content:center`.
struct FlexWrap: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews, maxWidth: maxWidth)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2   // justify-content:center
            for item in row.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func layout(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let add = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if add > maxWidth, !current.items.isEmpty {
                rows.append(current); current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append(i)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

struct BouncingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color(hexv: 0xff8a48)).frame(width: 5, height: 5)
                    .scaleEffect(on ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.18), value: on)
            }
        }
        .onAppear { on = true }
    }
}
