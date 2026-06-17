import SwiftUI

/// Root shell: warm window + custom title bar + icon rail + routed content + overlays.
/// Mirrors the Ember.dc layout (title bar · rail · main · Le fil · Mode Her · onboarding).
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showingCreate = false
    @State private var deleteTarget: PersonalModelInfo?

    var body: some View {
        ZStack {
            WindowGlassConfigurator().frame(width: 0, height: 0)
            WindowBackground()

            VStack(spacing: 0) {
                TopBar(showingCreate: $showingCreate)
                // title bar border-bottom: 1px rgba(255,255,255,0.06)
                Divider().overlay(.white.opacity(0.06))
                HStack(spacing: 0) {
                    Rail()
                    // rail border-right: 1px rgba(255,255,255,0.05)
                    Divider().overlay(.white.opacity(0.05))
                    ZStack {
                        content
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Fullscreen overlays
            if state.isHer {
                HerView().transition(.opacity)
            }
            if state.onboardOpen {
                OnboardingView().transition(.opacity)
            }
            if state.booting {
                BootOverlay().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: state.isHer)
        .animation(.easeInOut(duration: 0.28), value: state.onboardStep)
        .animation(.easeInOut(duration: 0.3), value: state.booting)
        .preferredColorScheme(.dark)
        .tint(.ember2)
        .sheet(isPresented: $showingCreate) { CreateSheet() }
        .alert("Oups", isPresented: .constant(state.errorText != nil)) {
            Button("OK") { state.errorText = nil }
        } message: { Text(state.errorText ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch state.view {
        case .home:     HomeView()
        case .ingest:   IngestView()
        case .memory:   MemoryView()
        case .settings: SettingsScreen()
        }
    }
}

// MARK: - Title bar (IA switcher + "100% local")
// Spec: height 48, padding 0 18px, gap 9; bg rgba(28,18,15,0.55) blur(24) saturate(160%);
// border-bottom 1px rgba(255,255,255,0.06). Traffic lights are native on macOS — we reserve
// their leading inset and center the switcher in the remaining width.

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showingCreate: Bool

    var body: some View {
        ZStack {
            // Centered IA switcher (the design's flex:1 center container)
            switcher
            HStack {
                Spacer()
                LocalPill()
            }
            .padding(.trailing, 18)
        }
        .frame(height: 48)
        .padding(.leading, 78)   // leave room for the native traffic-light controls
        .background(.ultraThinMaterial)
    }

    private var switcher: some View {
        let name = state.selected?.name ?? "Ember"
        let version = state.selected.map { "v\($0.version)" } ?? "v1"
        return Button {
            state.switcherOpen.toggle()
        } label: {
            HStack(spacing: 10) {
                // switcherBrand orb 18
                HStack(spacing: 9) {
                    EmberOrb(mode: .repos, size: 18).frame(width: 18, height: 18)
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(Color(hexv: 0xf0ddcf))
                }
                // version pill: 11px #9a8073, bg rgba(255,140,70,0.14), padding 2px 8px, radius 10
                Text(version)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0x9a8073))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(hexv: 0xff8c46).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                // chevron ▾: 10px #8a7d75, margin-left 2px
                Text("▾")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
                    .padding(.leading, 2)
            }
            // pill: padding 5px 8px 5px 14px, radius 22
            .padding(.leading, 14).padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color(hexv: 0xffdcc8).opacity(0.12), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $state.switcherOpen, arrowEdge: .bottom) {
            switcherMenu
        }
    }

    // Switcher dropdown — spec: width 300, padding 8, radius 16, bg rgba(30,20,16,0.82),
    // border rgba(255,220,200,0.14).
    private var switcherMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header label: 10.5px 700 letter-spacing 0.7 #7c6f67, padding 8px 10px 6px
            Text("MES IA — ISOLÉES & PRIVÉES")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Color(hexv: 0x7c6f67))
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)

            if state.models.isEmpty {
                Text("Aucune IA encore. Crées-en une.")
                    .font(.system(size: 12)).foregroundStyle(.emberMuted)
                    .padding(.horizontal, 11).padding(.vertical, 8)
            }
            ForEach(state.models) { m in
                let active = state.selected?.name == m.name
                Button { state.select(m); state.switcherOpen = false } label: {
                    HStack(spacing: 11) {
                        // dot 9px — hot = ember radial, else flat #4a3b34
                        Circle()
                            .fill(active
                                  ? AnyShapeStyle(RadialGradient(
                                        colors: [Color(hexv: 0xffcf9a), Color(hexv: 0xff6a26), Color(hexv: 0xc42a12)],
                                        center: UnitPoint(x: 0.35, y: 0.30), startRadius: 0, endRadius: 6))
                                  : AnyShapeStyle(Color(hexv: 0x4a3b34)))
                            .frame(width: 9, height: 9)
                            .shadow(color: active ? Color(hexv: 0xff6e32).opacity(0.7) : .clear, radius: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            // name 13.5px 600 #f0ddcf
                            Text(m.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Color(hexv: 0xf0ddcf))
                            // meta 11px #9a8073
                            Text("v\(m.version) · \(m.steps) pas")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hexv: 0x9a8073))
                        }
                        Spacer(minLength: 8)
                        if active {
                            // ✓ #ff8a48 13px
                            Text("✓").font(.system(size: 13)).foregroundStyle(Color(hexv: 0xff8a48))
                        }
                    }
                    // row: padding 10px 11px, radius 11, active bg rgba(255,120,60,0.12)
                    .padding(.horizontal, 11).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(active ? Color(hexv: 0xff783c).opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                // Right-click an IA to delete it (quick CRUD from the list)
                .contextMenu {
                    Button("Renommer dans Réglages…") { state.select(m); state.view = .settings; state.switcherOpen = false }
                    Divider()
                    Button("Supprimer « \(m.name) »", role: .destructive) {
                        Task { await state.deleteModel(m.name) }
                    }
                }
            }
            // "Nouvelle IA" — margin-top 4, padding 11px 12px, radius 11, dashed border
            // rgba(255,150,90,0.28), color #c79a82; "+" 16px, label 13px 600
            Button { state.switcherOpen = false; showingCreate = true } label: {
                HStack(spacing: 9) {
                    Text("+").font(.system(size: 16))
                    Text("Nouvelle IA").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color(hexv: 0xc79a82))
                .padding(.horizontal, 12).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(Color(hexv: 0xff965a).opacity(0.28)))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(8)
        .frame(width: 300)
        .background(Color(hexv: 0x1e1410).opacity(0.95))
    }
}

// MARK: - Icon rail
// Spec: width 84, flex column, align center, padding 18px 0, gap 6;
// bg rgba(20,13,11,0.5) blur(24) saturate(160%); border-right 1px rgba(255,255,255,0.05).

struct Rail: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 6) {
            // brandOrb 30, margin-bottom 14
            EmberOrb(mode: state.orbMode, size: 30).frame(width: 30, height: 30)
                .padding(.bottom, 14)

            // nav buttons (navStyle): width 64, gap 5, padding 11px 0, radius 15
            RailButton(system: "house", label: "Accueil", active: state.view == .home) { state.go(.home) }
            RailButton(system: "arrow.up.to.line", label: "Apprendre", active: state.view == .ingest) { state.go(.ingest) }
            RailButton(system: "brain", label: "Mémoire", active: state.view == .memory) { state.go(.memory) }
            RailButton(system: "gearshape", label: "Réglages", active: state.view == .settings) { state.go(.settings) }

            Spacer()   // flex:1

            // Mode Her — width 64, gap 5, padding 12px 0, radius 16,
            // border rgba(255,150,90,0.3), bg linear-gradient(160deg, rgba(255,120,60,0.18), rgba(255,90,40,0.06)),
            // color #ffcba6; icon 22; label 9.5px 700 letter-spacing 0.2
            Button { state.enterHer() } label: {
                VStack(spacing: 5) {
                    Image(systemName: "mic").font(.system(size: 22, weight: .regular))
                    Text("Mode Her").font(.system(size: 9.5, weight: .bold)).tracking(0.2)
                }
                .foregroundStyle(Color(hexv: 0xffcba6))
                .frame(width: 64).padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: [Color(hexv: 0xff783c).opacity(0.18),
                                                      Color(hexv: 0xff5a28).opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color(hexv: 0xff965a).opacity(0.3), lineWidth: 1))
                        .shadow(color: Color(hexv: 0xff5a28).opacity(0.5), radius: 10, y: 6)
                )
            }
            .buttonStyle(.plain)

            // Replay onboarding — margin-top 8, width 34 height 34, radius 10, color #7c6f67, icon 18
            Button { state.replayOnboard() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(hexv: 0x7c6f67))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("Rejouer l'onboarding")
            .padding(.top, 8)
        }
        .padding(.vertical, 18)
        .frame(width: 84)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Boot overlay

struct BootOverlay: View {
    var body: some View {
        ZStack {
            WindowBackground()
            VStack(spacing: 18) {
                EmberOrb(mode: .reflexion, size: 70).frame(height: 150)
                Text("Ember se réveille…")
                    .font(.emberSerif(18, weight: .regular).italic())
                    .foregroundStyle(.emberSerif)
            }
        }
    }
}

// MARK: - Create IA sheet

struct CreateSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var base = "qwen2.5-1.5b-instruct"

    // Honest (§2.4 — "la preuve, pas la promesse"): every IA runs on ONE local engine,
    // loaded once. We don't offer phantom model choices the engine doesn't actually run.
    private let bases = [
        ("qwen2.5-1.5b-instruct", "Qwen2.5-1.5B", "100% local · multilingue · optimisé Apple Silicon"),
    ]

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // header: small orb + serif title + subtitle
            HStack(spacing: 12) {
                EmberOrb(mode: .ecoute, size: 30).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Créer mon IA")
                        .font(.emberSerif(22)).foregroundStyle(.emberInk)
                    Text("Une mémoire neuve, isolée et 100% privée.")
                        .font(.system(size: 13)).foregroundStyle(.emberMuted)
                }
            }

            // name field
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Nom")
                TextField("ex : mon-assistant", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.emberInk)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(hexv: 0xff965a).opacity(0.28), lineWidth: 1))
            }

            // base model — selectable cards (matching Réglages)
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("Modèle de base")
                ForEach(bases, id: \.0) { b in
                    Button { base = b.0 } label: { baseCard(b) }
                        .buttonStyle(.plain)
                }
            }

            // actions
            HStack(spacing: 14) {
                Spacer()
                Button("Annuler") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.emberMuted)
                EmberCTA(title: "Créer", size: 13) {
                    guard !trimmed.isEmpty else { return }
                    Task { await state.create(name: trimmed, base: base); dismiss() }
                }
                .opacity(trimmed.isEmpty ? 0.45 : 1)
                .disabled(trimmed.isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(26)
        .frame(width: 430)
        .background(
            // a CONTAINED warm backdrop (not the full WindowBackground, whose blobs are
            // positioned off-screen for the 1440px window and muddy a small sheet).
            ZStack {
                Color(hexv: 0x140d0b)
                RadialGradient(
                    stops: [.init(color: Color(hexv: 0x2c1913).opacity(0.9), location: 0),
                            .init(color: Color(hexv: 0x140d0b), location: 1)],
                    center: .topLeading, startRadius: 0, endRadius: 460)
            }
        )
        .preferredColorScheme(.dark)
    }

    private func baseCard(_ b: (String, String, String)) -> some View {
        let sel = base == b.0
        return HStack(spacing: 12) {
            ZStack {
                Circle().strokeBorder(sel ? Color(hexv: 0xff8a48) : .white.opacity(0.22), lineWidth: 2)
                    .frame(width: 18, height: 18)
                if sel { Circle().fill(Color(hexv: 0xff8a48)).frame(width: 8, height: 8) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(b.1).font(.system(size: 14, weight: .semibold)).foregroundStyle(.emberInk)   // model id — language-neutral
                Text(LocalizedStringKey(b.2)).font(.system(size: 12)).foregroundStyle(.emberMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(sel
                      ? AnyShapeStyle(LinearGradient(colors: [Color(hexv: 0xff783c).opacity(0.14),
                                                              Color(hexv: 0xff5a28).opacity(0.04)],
                                                     startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(Color.white.opacity(0.035)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(sel ? Color(hexv: 0xffa064).opacity(0.35) : .white.opacity(0.07), lineWidth: 1)
        )
    }
}
