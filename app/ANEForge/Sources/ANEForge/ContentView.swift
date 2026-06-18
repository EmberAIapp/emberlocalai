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
                // Pas de séparation : en Her la barre est transparente (elle flotte sur l'ambiance) ;
                // en coulisse elle pose un voile dégradé (lisibilité) — jamais de trait dur.
                TopBar(showingCreate: $showingCreate)
                ZStack {
                    content   // Her (base) OU une coulisse (Apprendre/Mémoire/Réglages)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Fullscreen overlays
            if state.onboardOpen {
                OnboardingView().transition(.opacity)
            }
            if state.booting {
                BootOverlay().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.view)
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
        case .her:      HerView()                 // l'écran de base
        case .ingest:   IngestView()              // coulisse
        case .memory:   MemoryView()
        case .history:  HistoryView()
        case .settings: SettingsScreen()
        }
    }
}

// MARK: - Ghost hover (the ONLY thing that paints a background on a bar button)
// At rest a bar button is pure text+icon over the ambience — no fill, no stroke, no « séparation ».
// A faint capsule fades in only while hovered, so the affordance is there without boxing anything.
private struct GhostBG: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(.white.opacity(hovering ? 0.05 : 0)))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}
private extension View { func ghostHover() -> some View { modifier(GhostBG()) } }

// MARK: - Title bar (IA switcher au centre + nav coulisse + « 100% local »)
// Sans séparation : transparente en Her (flotte sur l'ambiance WindowBackground), voile dégradé
// en coulisse (lisibilité, jamais de trait). Hauteur 48 ; on réserve l'encoche des feux macOS.
// Responsive : sous une certaine largeur, les onglets passent en icône seule et la pastille en point.

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showingCreate: Bool

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width                       // largeur à droite des feux (post padding)
            let compact = usable < 760                        // → onglets en icône, pastille en point
            let nameMax: CGFloat = usable >= 980 ? 240 : (usable >= 760 ? 180 : 120)
            ZStack {
                // Centre : le nom de l'IA (sélecteur) — « le nom de l'IA au centre ».
                switcher(nameMax: nameMax)
                HStack(spacing: 10) {
                    // À gauche : revenir à Her quand on est en coulisse (remplace « Quitter »).
                    if state.view != .her {
                        Button { state.go(.her) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                                if !compact { Text("Ember").font(.system(size: 12.5, weight: .semibold)) }
                            }
                            .foregroundStyle(Color(hexv: 0xd8c6ba))
                            .shadow(color: kBarGlyphShadow, radius: 5)
                            .padding(.vertical, 5).padding(.horizontal, 11)
                            .ghostHover()
                        }
                        .buttonStyle(.plain).help("Revenir à Ember")
                    }
                    Spacer(minLength: 8)
                    // À droite : la coulisse — Apprendre · Mémoire · Réglages.
                    NavTab(icon: "arrow.up.to.line",       label: "Apprendre",  target: .ingest,   showLabel: !compact)
                    NavTab(icon: "brain",                  label: "Mémoire",    target: .memory,   showLabel: !compact)
                    NavTab(icon: "clock.arrow.circlepath", label: "Historique", target: .history,  showLabel: !compact)
                    NavTab(icon: "gearshape",              label: "Réglages",   target: .settings, showLabel: !compact)
                    LocalPill(compact: compact)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 48)                                // clamp interne (GeometryReader est gourmand)
            .animation(.easeInOut(duration: 0.16), value: compact)
        }
        .frame(height: 48)                                   // clamp externe — garde le rythme 48pt
        .padding(.leading, 78)                               // encoche des feux natifs
        .background(barBackground)                           // remplace .ultraThinMaterial
    }

    // Her : aucune séparation (transparent → WindowBackground transparaît). Coulisse : voile dégradé
    // qui se fond vers le bas (lisibilité sur le contenu qui défile), sans aucun bord.
    @ViewBuilder private var barBackground: some View {
        if state.view == .her {
            Color.clear
        } else {
            LinearGradient(stops: [
                .init(color: Color(hexv: 0x140d0b).opacity(0.90), location: 0.0),
                .init(color: Color(hexv: 0x140d0b).opacity(0.45), location: 0.6),
                .init(color: .clear,                               location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
            .background(.ultraThinMaterial)
            .allowsHitTesting(false)
        }
    }

    private func switcher(nameMax: CGFloat) -> some View {
        let name = state.selected?.name ?? "Ember"
        // Honest badge: how many facts Ember knows (real), not a fake training "version".
        let factCount = state.facts.count
        return Button {
            state.switcherOpen.toggle()
        } label: {
            HStack(spacing: 10) {
                // switcherBrand orb 18 — LIVE (reflects the real state, §3 "partout")
                HStack(spacing: 9) {
                    EmberOrb(mode: state.orbMode, size: 18).frame(width: 18, height: 18)
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(Color(hexv: 0xf0ddcf))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: nameMax, alignment: .leading)   // tronque → jamais dans les côtés
                        .shadow(color: kBarGlyphShadow, radius: 5)
                }
                // fact-count : texte plat « · N faits » (la pastille orange « séparait » → supprimée)
                if state.selected != nil {
                    Text("· \(factCount) fait\(factCount > 1 ? "s" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hexv: 0x9a8073))
                        .shadow(color: kBarGlyphShadow, radius: 5)
                }
                // chevron ▾
                Text("▾")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
                    .shadow(color: kBarGlyphShadow, radius: 5)
                    .padding(.leading, 2)
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .padding(.vertical, 5)
            .ghostHover()                                                // plat ; fond seulement au survol
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
                            // meta 11px #9a8073 — honnête : pas de fausse « version/pas d'entraînement »
                            Text("IA locale")
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

// MARK: - Nav tab (top-right : Apprendre · Mémoire · Réglages → coulisse)
// Plat, sans « séparation de fond » : au repos = icône + texte qui flottent ; au survol un fond
// capsule s'estompe ; l'état actif (en coulisse) se lit par la teinte chaude + un soulignement 2px
// auto-épinglé (jamais de boîte, jamais de saut de mise en page). `showLabel` → responsive (icône seule).
struct NavTab: View {
    @EnvironmentObject var state: AppState
    let icon: String
    let label: String
    let target: MainView
    var showLabel: Bool = true
    @State private var hovering = false

    var body: some View {
        let active = state.view == target          // en Her, faux pour les trois → rien d'actif
        Button { state.go(target) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: active ? .semibold : .medium))
                if showLabel {
                    Text(LocalizedStringKey(label)).font(.system(size: 12.5, weight: active ? .semibold : .medium))
                }
            }
            .foregroundStyle(active ? Color(hexv: 0xffb877) : Color(hexv: 0xc9bbb1))
            .shadow(color: kBarGlyphShadow, radius: 5)
            .padding(.vertical, 5).padding(.horizontal, 11)
            .background(Capsule().fill(.white.opacity(hovering ? 0.05 : 0)))     // survol seulement, sans bord
            .overlay(alignment: .bottom) {                                       // actif = soulignement
                Capsule()
                    .fill(LinearGradient(colors: [Color(hexv: 0xffb877), Color(hexv: 0xff7a3a)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                    .padding(.horizontal, 11)
                    .opacity(active ? 1 : 0)                                     // pas de saut de layout
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey(label))           // nomme l'onglet même en icône seule
        .onHover { hovering = $0 }
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
