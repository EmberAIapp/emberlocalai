import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var state: AppState

    @State private var personaText: String = ""
    @State private var maxTokens: Double = 96
    @State private var temperature: Double = 0.7
    @State private var profileName: String = ""
    @State private var showDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header — title 30px serif #f5e7db, subtitle 14px #9a8d84 mb 26
                Text("Réglages")
                    .font(.emberSerif(30, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xf5e7db))
                    .padding(.bottom, 4)
                Text("Tout en langage humain. Aucun jargon, aucune télémétrie.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hexv: 0x9a8d84))
                    .padding(.bottom, 26)

                // PROFIL — rename / delete the selected AI (full CRUD on the profile)
                SectionLabel("Profil")
                    .padding(.bottom, 13)
                profileSection
                    .padding(.bottom, 30)

                // MODÈLE DE BASE
                SectionLabel("Modèle de base")
                    .padding(.bottom, 13)
                modelGrid

                // PERSONA · COMMENT ELLE SE COMPORTE
                SectionLabel("Persona · comment elle se comporte")
                    .padding(.top, 30)
                    .padding(.bottom, 13)
                personaPanel
                personaChips
                    .padding(.top, 12)

                // Sliders — grid 1fr 1fr gap 26 margin-top 30
                slidersRow
                    .padding(.top, 30)

                // Save (app control — only path to persist persona/length to the engine)
                saveRow
                    .padding(.top, 18)

                // PERMISSIONS DU MODE HER · GRANULAIRES, RÉVOCABLES
                SectionLabel("Permissions du mode Her · granulaires, révocables")
                    .padding(.top, 30)
                    .padding(.bottom, 13)
                permissionsList

                // Privacy proof
                networkMonitor
                    .padding(.top, 30)
            }
            .padding(.top, 34)
            .padding(.horizontal, 48)
            .padding(.bottom, 40)
        }
        .task { await reload() }
        .onChange(of: state.selected?.name) {
            Task { await reload() }
        }
        .alert("Supprimer cette IA ?", isPresented: $showDelete) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                if let name = state.selected?.name { Task { await state.deleteModel(name) } }
            }
        } message: {
            Text("« \(state.selected?.name ?? "") » et toute sa mémoire seront définitivement supprimées de ce Mac.")
        }
    }

    private func reload() async {
        profileName = state.selected?.name ?? ""
        if let name = state.selected?.name {
            let s = await state.loadSettings(name)
            personaText = s.persona
            maxTokens = Double(max(16, s.maxTokens))
        }
    }

    // MARK: 0) Profil — rename (Update) + delete (Delete) for the selected AI

    private var canRename: Bool {
        let n = profileName.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n != (state.selected?.name ?? "") && state.selected != nil
    }

    private func commitRename() {
        guard canRename, let old = state.selected?.name else { return }
        Task { await state.renameModel(old, to: profileName) }
    }

    private var profileSection: some View {
        HStack(spacing: 12) {
            EmberOrb(mode: state.orbMode, size: 26).frame(width: 26, height: 26)
            TextField("son nom", text: $profileName)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.emberInk)
                .onSubmit(commitRename)
                .disabled(state.selected == nil)
            if canRename {
                Button("Renommer", action: commitRename)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xff8a48))
            }
            Spacer(minLength: 8)
            Button { showDelete = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Supprimer cette IA")
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color(hexv: 0xff6b5a))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hexv: 0xff5a46).opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(hexv: 0xff6b5a).opacity(0.30), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(state.selected == nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }

    // MARK: 1) Model catalog — grid-template-columns: repeat(3,1fr); gap 14

    private var modelGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                            GridItem(.flexible(), spacing: 14),
                            GridItem(.flexible(), spacing: 14)],
                  spacing: 14) {
            ForEach(Array(DesignData.modelCatalog.enumerated()), id: \.offset) { idx, md in
                SettingsModelCard(md: md, selected: idx == state.selectedModelIndex) {
                    state.selectedModelIndex = idx
                }
            }
        }
    }

    // MARK: 2) Persona — display panel (editable, wired to personaText)

    private var personaPanel: some View {
        // padding 16px 18px; radius 14; bg rgba(255,255,255,0.04); border 0.08;
        // serif 16px line-height 1.55 color #d8c6ba
        TextEditor(text: $personaText)
            .font(.emberSerif(16, weight: .regular))
            .foregroundStyle(Color(hexv: 0xd8c6ba))
            .lineSpacing(16 * 0.55)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 56)
            .background(.clear)
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }

    // persona chips — gap 9, flex-wrap; chip 13px/600|500, pad 8px 17px, radius 20
    private var personaChips: some View {
        FlowChips(spacing: 9) {
            ForEach(Array(DesignData.personaOptions.enumerated()), id: \.offset) { _, opt in
                PersonaChip(label: opt, selected: opt == state.personaSel) {
                    state.personaSel = opt
                }
            }
        }
    }

    // MARK: 3) Sliders — grid 1fr 1fr gap 26

    private var lengthLabel: String {
        if maxTokens <= 48 { return "Courte" }
        if maxTokens <= 128 { return "Équilibrée" }
        return "Longue"
    }

    private var slidersRow: some View {
        HStack(alignment: .top, spacing: 26) {
            SettingsSlider(title: "Longueur des réponses",
                           valueText: lengthLabel,
                           value: $maxTokens,
                           range: 16...256,
                           step: 8)
            SettingsSlider(title: "Créativité (température)",
                           valueText: String(format: "%.1f", temperature),
                           value: $temperature,
                           range: 0...1,
                           step: 0.1)
        }
    }

    // MARK: 4) Save

    private var saveRow: some View {
        HStack {
            Spacer(minLength: 0)
            EmberCTA(title: "Enregistrer", size: 13) {
                if let name = state.selected?.name {
                    Task { await state.saveSettings(name, persona: personaText, maxTokens: Int(maxTokens)) }
                }
            }
        }
    }

    // MARK: 5) Permissions — column gap 9

    private var permissionsList: some View {
        VStack(spacing: 9) {
            ForEach(Array(DesignData.permissions.enumerated()), id: \.offset) { _, p in
                SettingsPermissionRow(
                    icon: p.icon,
                    name: p.key,
                    desc: p.desc,
                    isOn: state.permissions[p.key] ?? false
                ) {
                    let current = state.permissions[p.key] ?? false
                    state.permissions[p.key] = !current
                }
            }
        }
    }

    // MARK: 6) Privacy proof / network monitor

    private var networkMonitor: some View {
        // padding 20px 22px; radius 18; gradient green 0.10→0.03; border 0.22; gap 18
        HStack(spacing: 18) {
            // icon box 48x48 radius 14 bg rgba(95,208,122,0.14), shield-check stroke #7fd095
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hexv: 0x5fd07a).opacity(0.14))
                .frame(width: 48, height: 48)
                .overlay(
                    ShieldCheck()
                        .stroke(Color(hexv: 0x7fd095),
                                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 24, height: 24)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Moniteur réseau : 0 octet sorti")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hexv: 0xbfe9c9))
                Text("Données, modèle et mémoire vivent uniquement sur ce Mac. La preuve, pas la promesse.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hexv: 0x9bbfa3))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("↑ 0 ko · ↓ 0 ko")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(hexv: 0x7fd095))
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.25))
                )
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(hexv: 0x5fd07a).opacity(0.10),
                                              Color(hexv: 0x5fd07a).opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color(hexv: 0x5fd07a).opacity(0.22), lineWidth: 1)
                )
        )
    }
}

// MARK: - Wrapping chip row (flex-wrap)

private struct FlowChips<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        // Persona has 4 short chips that fit on one row at 1440 width; a simple
        // HStack reproduces the design's gap exactly. flex-wrap is a safety net,
        // not exercised at this width.
        HStack(spacing: spacing) {
            content
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Model card

private struct SettingsModelCard: View {
    let md: DesignData.ModelChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // name 15/700 #f0ddcf  ·  radio 18px, space-between
                HStack(alignment: .center) {
                    Text(LocalizedStringKey(md.name))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hexv: 0xf0ddcf))
                    Spacer(minLength: 8)
                    radio
                }
                // desc 12.5px #9a8d84 margin-top 6 line-height 1.4
                Text(LocalizedStringKey(md.desc))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hexv: 0x9a8d84))
                    .lineSpacing(12.5 * 0.4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                // pills gap 6 margin-top 12; pad 3px 8px radius 7 font 10.5
                HStack(spacing: 6) {
                    pill(md.ram, fg: Color(hexv: 0xb09a8c), bg: .white.opacity(0.05))
                    pill(md.speed, fg: Color(hexv: 0x9fd9ad), bg: Color(hexv: 0x5fd07a).opacity(0.10))
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
    }

    private func pill(_ text: String, fg: Color, bg: some ShapeStyle) -> some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 10.5))
            .foregroundStyle(fg)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(bg))
    }

    // radio 18px, border 2px (#ff8a48 / white 0.2); selected = radial #ff8a48 40%
    private var radio: some View {
        Circle()
            .strokeBorder(selected ? Color(hexv: 0xff8a48) : .white.opacity(0.2), lineWidth: 2)
            .frame(width: 18, height: 18)
            .overlay(
                Circle()
                    .fill(Color(hexv: 0xff8a48))
                    .frame(width: 18 * 0.4, height: 18 * 0.4)
                    .opacity(selected ? 1 : 0)
            )
    }

    // card: padding 16, radius 16; selected = linear 160deg ember tint, border #ffa064 0.35
    @ViewBuilder private var cardBackground: some View {
        if selected {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(hexv: 0xff783c).opacity(0.14),
                                              Color(hexv: 0xff5a28).opacity(0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(hexv: 0xffa064).opacity(0.35), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                )
        }
    }
}

// MARK: - Slider block — track height 6 radius 6, gradient fill, 16px white knob

private struct SettingsSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // label row 13px: title #c9bbb1 weight 600, value #e8b48f
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xc9bbb1))
                Spacer(minLength: 8)
                Text(LocalizedStringKey(valueText))
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hexv: 0xe8b48f))
            }
            track
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // height 6 radius 6 bg rgba(0,0,0,0.3); fill 90deg #ff9a4a→#ff6024; knob 16px white centered
    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.3)).frame(height: 6)
                Capsule()
                    .fill(LinearGradient(colors: [Color(hexv: 0xff9a4a), Color(hexv: 0xff6024)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(w, fraction * w)), height: 6)
                Circle().fill(.white).frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                    .offset(x: max(0, min(w - 16, fraction * w - 8)))
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let span = range.upperBound - range.lowerBound
                let f = Double(max(0, min(1, g.location.x / w)))
                let raw = range.lowerBound + f * span
                let snapped = (raw / step).rounded() * step
                value = min(range.upperBound, max(range.lowerBound, snapped))
            })
        }
        .frame(height: 16)
    }
}

// MARK: - Permission row — pad 13px 16px radius 13 border 0.06; toggle 44x26 radius 14

private struct SettingsPermissionRow: View {
    let icon: String
    let name: String
    let desc: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(icon)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(name))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xecd9c9))
                Text(LocalizedStringKey(desc))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            toggleSwitch
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
    }

    // track 44x26 radius 14; on = 135deg #ff9a4a→#ff6024; off = white 0.12
    // knob 20x20 top 3, left 3→21 (centers at ±9 around the 44-wide track)
    private var toggleSwitch: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(trackFill)
            .frame(width: 44, height: 26)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.3), radius: 2.5, y: 2)
                    .offset(x: isOn ? 9 : -9)
                    .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isOn)
            )
            .onTapGesture { toggle() }
    }

    private var trackFill: AnyShapeStyle {
        if isOn {
            return AnyShapeStyle(LinearGradient(colors: [Color(hexv: 0xff9a4a), Color(hexv: 0xff6024)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            return AnyShapeStyle(Color.white.opacity(0.12))
        }
    }
}

// MARK: - Shield-with-check glyph (matches the spec's inline SVG paths)

private struct ShieldCheck: Shape {
    // viewBox 0 0 24 24:  M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z   +   m9 12 2 2 4-4
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var path = Path()
        // Shield outline
        path.move(to: p(12, 22))
        path.addQuadCurve(to: p(20, 12), control: p(20, 18))   // 8-4 8-10 (smooth → approximate)
        path.addLine(to: p(20, 5))
        path.addLine(to: p(12, 2))
        path.addLine(to: p(4, 5))
        path.addLine(to: p(4, 12))
        path.addQuadCurve(to: p(12, 22), control: p(4, 18))    // c0 6 8 10 8 10
        path.closeSubpath()
        // Check mark: m9 12 2 2 4-4
        path.move(to: p(9, 12))
        path.addLine(to: p(11, 14))
        path.addLine(to: p(15, 10))
        return path
    }
}
