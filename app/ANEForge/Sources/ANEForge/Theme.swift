import SwiftUI

// MARK: - Color from hex

extension Color {
    init(hexv: UInt) {
        self.init(.sRGB,
                  red: Double((hexv >> 16) & 0xff) / 255,
                  green: Double((hexv >> 8) & 0xff) / 255,
                  blue: Double(hexv & 0xff) / 255,
                  opacity: 1)
    }
}

// MARK: - Ember palette (exact values from the Ember.dc design)

extension ShapeStyle where Self == Color {
    // Surfaces
    static var emberBg: Color     { Color(hexv: 0x0a0605) }   // deepest
    static var emberBg2: Color    { Color(hexv: 0x140d0b) }   // window base
    static var emberPanel: Color  { Color(hexv: 0x1a120f) }   // panels
    // Ink
    static var emberInk: Color    { Color(hexv: 0xf3e9e2) }   // primary text
    static var emberInk2: Color   { Color(hexv: 0xf0ddcf) }   // warm headings (switcher name #f0ddcf)
    static var emberMuted: Color  { Color(hexv: 0x9a8d84) }   // secondary text
    static var emberFaint: Color  { Color(hexv: 0x7c6f67) }   // labels / hints
    static var emberSerif: Color  { Color(hexv: 0xb09a8c) }   // serif captions
    // Ember accents
    static var ember1: Color      { Color(hexv: 0xffb877) }   // light
    static var ember2: Color      { Color(hexv: 0xff7a3a) }   // core orange (persona gradient end)
    static var ember3: Color      { Color(hexv: 0xff6024) }   // hot (CTA gradient end)
    static var emberDeep: Color   { Color(hexv: 0x1a0f0a) }   // on-ember text
    // "100% local" green
    static var localGreen: Color  { Color(hexv: 0x5fd07a) }
    static var localGreen2: Color { Color(hexv: 0x7fd095) }
}

// MARK: - Typography — Newsreader is the literary serif; New York (system serif) is the native match

extension Font {
    /// Editorial serif — used for Ember's "voice" and section titles.
    static func emberSerif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Liquid Glass panel

struct GlassPanel: ViewModifier {
    var corner: CGFloat = 16
    var strokeOpacity: Double = 0.08
    var fillOpacity: Double = 0.04
    func body(content: Content) -> some View {
        content
            .background(.white.opacity(fillOpacity))
            .background(.ultraThinMaterial.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

extension View {
    func glassPanel(corner: CGFloat = 16, strokeOpacity: Double = 0.08, fillOpacity: Double = 0.04) -> some View {
        modifier(GlassPanel(corner: corner, strokeOpacity: strokeOpacity, fillOpacity: fillOpacity))
    }

    /// A glass card — now backed by the real liquid-glass surface (frosts the window behind it).
    /// Design card (renderArtifact L171): radius 18, fill rgba(255,255,255,0.045), blur(20),
    /// border rgba(255,220,200,0.13), shadow + inset top highlight.
    func glassCard(corner: CGFloat = 18, stroke: Double = 0.07, fill: Double = 0.045, shadow: Bool = true) -> some View {
        liquidGlass(corner: corner, tint: fill + 0.01, rimOpacity: 0.14, shadow: shadow)
    }
}

// MARK: - The warm "Her" window background (radial ember light + ambient blobs)

struct WindowBackground: View {
    var body: some View {
        ZStack {
            // body { background: radial-gradient(130% 100% at 50% -10%, #2c1913, #150d0a 48%, #0a0605) }
            RadialGradient(stops: [
                .init(color: Color(hexv: 0x2c1913), location: 0),
                .init(color: Color(hexv: 0x150d0a), location: 0.48),
                .init(color: Color(hexv: 0x0a0605), location: 1)],
                center: UnitPoint(x: 0.5, y: -0.10), startRadius: 0, endRadius: 1100)
            // warm ambient blobs — spec: rgba(255,110,50,0.16) top-left 520, rgba(255,150,80,0.10) bottom-right 480
            Circle()
                .fill(RadialGradient(colors: [Color(hexv: 0xff6e32).opacity(0.16), .clear],
                                     center: .center, startRadius: 0, endRadius: 260))
                .frame(width: 520, height: 520).blur(radius: 40)
                .offset(x: -120, y: -300)
            Circle()
                .fill(RadialGradient(colors: [Color(hexv: 0xff9650).opacity(0.10), .clear],
                                     center: .center, startRadius: 0, endRadius: 240))
                .frame(width: 480, height: 480).blur(radius: 50)
                .offset(x: 360, y: 360)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - "100% local" green pill (the privacy signature)
// Spec (shell L45-48): padding 5x11, gap 7, dot 6px glow #5fd07a, text 11/600 #9fd9ad,
// bg rgba(95,208,122,0.10), border rgba(95,208,122,0.22).

struct LocalPill: View {
    var text: String = "100% local"
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.localGreen).frame(width: 6, height: 6)
                .shadow(color: .localGreen, radius: 4)
            Text(LocalizedStringKey(text)).font(.system(size: 11, weight: .semibold)).tracking(0.2)
                .foregroundStyle(Color(hexv: 0x9fd9ad))
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Color(hexv: 0x5fd07a).opacity(0.10))
        .overlay(Capsule().strokeBorder(Color(hexv: 0x5fd07a).opacity(0.22), lineWidth: 1))
        .clipShape(Capsule())
    }
}

// MARK: - Uppercase section label (faint, letter-spaced)
// Spec switcher header (shell L26): fontSize 10.5, weight 700, tracking 0.7, color #7c6f67.
// Menu/artifact section names (logic L114): fontSize 11, weight 700, tracking 0.8, color #c79a82.
// Generic shared label keeps the faint variant; callers override color where the warm tone is needed.

struct SectionLabel: View {
    let text: LocalizedStringKey         // LocalizedStringKey so interpolated labels ("Faits · \(n)") localize as "Faits · %lld"
    var color: Color = .emberFaint
    var size: CGFloat = 11
    var tracking: CGFloat = 0.8
    init(_ text: LocalizedStringKey, color: Color = .emberFaint, size: CGFloat = 11, tracking: CGFloat = 0.8) {
        self.text = text; self.color = color; self.size = size; self.tracking = tracking
    }
    var body: some View {
        Text(text)
            .textCase(.uppercase)          // localize the original-case key, display uppercased
            .font(.system(size: size, weight: .bold))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

// MARK: - Pill tag (small colored capsule)
// Used for category badges (memory facts logic L488-490), connector/source status pills
// (logic L468-469, L477-478) and the switcher version chip (shell L21): fontSize 10.5-11,
// weight 600, padding ~3-4 x 8-11, radius 10.

struct TagPill: View {
    let text: String
    var fg: Color
    var bg: Color
    var radius: CGFloat = 10
    var fontSize: CGFloat = 10.5
    var tracking: CGFloat = 0
    var hPad: CGFloat = 9
    var vPad: CGFloat = 3
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: fontSize, weight: .semibold))
            .tracking(tracking)
            .foregroundStyle(fg)
            .padding(.horizontal, hPad).padding(.vertical, vPad)
            .background(bg).clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

// MARK: - Chip button (suggestions, persona, modes)
// Mode chips (logic L428-439): fontSize 12.5, weight active 600 / 500, padding 7x15, radius 20,
// color active #1a0f0a / inactive #9a8d84, active gradient linear-gradient(135deg, glow@0.95, glow@0.7),
// border active glow@0.6 / inactive rgba(255,255,255,0.08), inactive bg rgba(255,255,255,0.04),
// active shadow 0 4px 18px -4px glow@0.6, tracking 0.2.
// `glow` lets callers feed the active mode's glow; defaults to the ember light→core ramp.

struct ChipButton: View {
    let label: String
    var selected: Bool = false
    var leading: String? = nil   // optional ✦ glyph
    var glow: Color = .ember2    // active accent (mode.glow for mode chips)
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let l = leading { Text(l) }
                Text(LocalizedStringKey(label))
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
            .tracking(0.2)
            .foregroundStyle(selected ? Color.emberDeep : Color.emberMuted)
            .padding(.horizontal, 15).padding(.vertical, 7)
            .background {
                if selected {
                    Capsule().fill(LinearGradient(
                        colors: [glow.opacity(0.95), glow.opacity(0.70)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Capsule().strokeBorder(glow.opacity(0.6), lineWidth: 1))
                } else {
                    Capsule().fill(.white.opacity(0.04))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                }
            }
            .shadow(color: selected ? glow.opacity(0.6) : .clear, radius: 9, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Persona chip (Réglages tempérament selector)
// Spec (logic L517-524): fontSize 13, weight active 600 / 500, padding 8x17, radius 20,
// color active #1a0f0a / inactive #b09a8c, active gradient linear-gradient(135deg,#ffb877,#ff7a3a),
// border active rgba(255,160,100,0.5) / inactive rgba(255,255,255,0.1), inactive bg rgba(255,255,255,0.05).

struct PersonaChip: View {
    let label: String
    var selected: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.emberDeep : Color.emberSerif)
                .padding(.horizontal, 17).padding(.vertical, 8)
                .background {
                    if selected {
                        Capsule().fill(LinearGradient(colors: [.ember1, .ember2],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Capsule().strokeBorder(Color(hexv: 0xffa064).opacity(0.5), lineWidth: 1))
                    } else {
                        Capsule().fill(.white.opacity(0.05))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Primary ember CTA (gradient capsule)
// Learn button / primary CTA (logic L638-641): gradient linear-gradient(135deg,#ffb877,#ff6024),
// fontSize 12.5, weight 700, padding 8x16, radius 20, color #1a0f0a, shadow 0 6px 18px -6px rgba(255,90,40,0.6).
// Larger hero CTAs scale padding from `size`.

struct EmberCTA: View {
    let title: String
    var size: CGFloat = 12.5
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color.emberDeep)
                .padding(.horizontal, max(16, size * 1.28))
                .padding(.vertical, max(8, size * 0.64))
                .background(LinearGradient(colors: [.ember1, .ember3],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(Capsule())
                .shadow(color: Color(hexv: 0xff5a28).opacity(0.6), radius: 9, y: 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rail nav button (icon + label, active state)
// Nav style (logic L406-417): width 64, padding 11x0, gap 5, radius 15,
// active gradient linear-gradient(160deg,rgba(255,120,60,0.16),rgba(255,90,40,0.04)),
// active border rgba(255,170,120,0.25), color active #ffcba6 / inactive #8a7d75,
// icon 22px stroke 1.7, label 9.5/600 tracking 0.2.

struct RailButton: View {
    let system: String        // SF Symbol
    let label: LocalizedStringKey   // localizes via Localizable.strings
    var active: Bool = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: system)
                    .font(.system(size: 22, weight: .regular))
                Text(label).font(.system(size: 9.5, weight: .semibold)).tracking(0.2)
            }
            .foregroundStyle(active ? Color(hexv: 0xffcba6) : (hover ? .emberInk2 : Color(hexv: 0x8a7d75)))
            .frame(width: 64)
            .padding(.vertical, 11)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(LinearGradient(colors: [Color(hexv: 0xff783c).opacity(0.16),
                                                      Color(hexv: 0xff5a28).opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 15)
                            .strokeBorder(Color(hexv: 0xffaa78).opacity(0.25), lineWidth: 1))
                } else if hover {
                    RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.04))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Orb modes (1:1 with the design's MODES)

enum OrbMode: String, CaseIterable {
    case repos, ecoute, reflexion, parle, apprend, erreur

    var label: LocalizedStringKey {
        switch self {
        case .repos: return "Repos"
        case .ecoute: return "Écoute"
        case .reflexion: return "Réflexion"
        case .parle: return "Réponse"
        case .apprend: return "Apprentissage"
        case .erreur: return "Erreur"
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .repos: return "Je suis là."
        case .ecoute: return "Je t’écoute…"
        case .reflexion: return "Je réfléchis."
        case .parle: return "Je te réponds…"
        case .apprend: return "J’apprends de toi."
        case .erreur: return "Un souci est survenu."
        }
    }

    /// Core radial-gradient stops (inner → outer), matching the design hex ramps.
    var coreStops: [Gradient.Stop] {
        // Dense stops pre-sampled in sRGB (like the browser) so SwiftUI's linear-space
        // interpolation can't drift the midtones red/dark — matches the HTML coral exactly.
        switch self {
        case .repos:
            return ramp([0xFFE3BC, 0xFFD2A1, 0xFFC086, 0xFFAF6B, 0xFF9E50, 0xFF8D44, 0xFF7F3A, 0xFF7130, 0xFF6024, 0xF1531F, 0xE2451A, 0xD63916, 0xC82C11, 0x9B220E, 0x73190A, 0x460F07],
                        [0, 0.06, 0.12, 0.18, 0.24, 0.31, 0.37, 0.43, 0.5, 0.57, 0.64, 0.7, 0.77, 0.85, 0.92, 1])
        case .ecoute:
            return ramp([0xFFEAC8, 0xFFD8AA, 0xFFC68C, 0xFFB46E, 0xFFA456, 0xFF9449, 0xFF873E, 0xFF7933, 0xFC6A28, 0xF25B23, 0xE84C1D, 0xDF3F19, 0xD03114, 0xA32610, 0x7B1D0C, 0x4E1208],
                        [0, 0.06, 0.12, 0.18, 0.24, 0.31, 0.37, 0.43, 0.5, 0.57, 0.64, 0.7, 0.77, 0.85, 0.92, 1])
        case .reflexion:
            return ramp([0xFFE0B0, 0xFFC489, 0xFFA763, 0xFF8A3C, 0xFD762B, 0xFA6423, 0xF6541C, 0xF44415, 0xE93711, 0xDA2F0F, 0xCA270D, 0xBD210B, 0xA61A09, 0x821508, 0x621107, 0x3E0C05],
                        [0, 0.06, 0.12, 0.18, 0.24, 0.31, 0.37, 0.43, 0.5, 0.57, 0.64, 0.7, 0.77, 0.85, 0.92, 1])
        case .parle:
            return ramp([0xFFE8C2, 0xFFD5A4, 0xFFC286, 0xFFAF68, 0xFF9E51, 0xFF8F45, 0xFF823B, 0xFF7530, 0xFC6626, 0xF15720, 0xE5491A, 0xDC3C14, 0xCC2F0F, 0x9F240C, 0x771B0A, 0x4A1107],
                        [0, 0.06, 0.12, 0.18, 0.24, 0.31, 0.37, 0.43, 0.5, 0.57, 0.64, 0.7, 0.77, 0.85, 0.92, 1])
        case .apprend:
            return ramp([0xFFF3DF, 0xFFE3BE, 0xFFD39E, 0xFFC37D, 0xFFB568, 0xFFA556, 0xFF9846, 0xFF8B37, 0xFB7A2B, 0xF36824, 0xEB561C, 0xE44616, 0xD13711, 0xA92B0F, 0x86200C, 0x5E140A],
                        [0, 0.06, 0.12, 0.18, 0.24, 0.31, 0.37, 0.43, 0.5, 0.57, 0.64, 0.7, 0.77, 0.85, 0.92, 1])
        case .erreur:   // pulsation d'alerte rouge (§3), puis retour au calme
            return ramp([0xFFD2C2, 0xFFB0A0, 0xFF8E7E, 0xFF6C5C, 0xFB4E44, 0xF23C38, 0xE63232, 0xD82A2A, 0xC72222, 0xB41C1C, 0xA01717, 0x8A1313, 0x720F0F, 0x560B0B, 0x3A0808, 0x240505],
                        [0, 0.06, 0.12, 0.18, 0.24, 0.31, 0.37, 0.43, 0.5, 0.57, 0.64, 0.7, 0.77, 0.85, 0.92, 1])
        }
    }

    /// Highlight center of the ember core.
    var coreCenter: UnitPoint {
        switch self {
        case .reflexion: return UnitPoint(x: 0.40, y: 0.32)
        case .apprend:   return UnitPoint(x: 0.40, y: 0.30)
        default:         return UnitPoint(x: 0.38, y: 0.30)
        }
    }

    var glow: Color {
        switch self {
        case .repos:     return Color(hexv: 0xff823c)
        case .ecoute:    return Color(hexv: 0xff9646)
        case .reflexion: return Color(hexv: 0xff5028)
        case .parle:     return Color(hexv: 0xff8c46)
        case .apprend:   return Color(hexv: 0xffaa5a)
        case .erreur:    return Color(hexv: 0xff4038)
        }
    }

    var dot: Color {
        switch self {
        case .repos:     return Color(hexv: 0xff9a4a)
        case .ecoute:    return Color(hexv: 0xffb15c)
        case .reflexion: return Color(hexv: 0xff6a3a)
        case .parle:     return Color(hexv: 0xffa050)
        case .apprend:   return Color(hexv: 0xffc06e)
        case .erreur:    return Color(hexv: 0xff5a52)
        }
    }

    var intensity: Double {
        switch self {
        case .repos: return 0.55
        case .ecoute: return 0.80
        case .reflexion: return 1.0
        case .parle: return 0.78
        case .apprend: return 0.90
        case .erreur: return 1.0
        }
    }

    // Animation shape per mode.
    var coreScale: CGFloat {     // peak scale of the breathing/pulsing core
        switch self {
        case .repos: return 1.045
        case .ecoute: return 1.10
        case .reflexion: return 1.05
        case .parle: return 1.10
        case .apprend: return 1.07
        case .erreur: return 1.13
        }
    }
    var coreDuration: Double {
        switch self {
        case .repos: return 2.75
        case .ecoute: return 0.85
        case .reflexion: return 0.5
        case .parle: return 1.3
        case .apprend: return 1.0
        case .erreur: return 0.4   // pulsation d'alerte rapide
        }
    }
    var haloDuration: Double {
        switch self {
        case .repos: return 3.0
        case .ecoute: return 0.85
        case .reflexion: return 0.65
        case .parle: return 1.3
        case .apprend: return 1.0
        case .erreur: return 0.4
        }
    }
    /// Whether the core also flickers brighter (reflexion / apprend).
    var flickers: Bool { self == .reflexion || self == .apprend }
    var ripples: Bool { self == .parle }

    private func ramp(_ hexes: [UInt], _ locs: [Double]) -> [Gradient.Stop] {
        zip(hexes, locs).map { Gradient.Stop(color: Color(hexv: $0.0), location: $0.1) }
    }
}

// MARK: - The Ember orb — Liquid Glass over a living ember

struct EmberOrb: View {
    var mode: OrbMode = .repos
    var size: CGFloat = 84

    @State private var pulse = false      // core scale
    @State private var haloPulse = false  // halo scale/opacity
    @State private var flick = false      // brightness flicker
    @State private var ripple = false     // parle ripples

    var body: some View {
        // Only the size-sized sphere drives layout. The halo (size*2.5) and ripples are drawn
        // in a non-expanding background so they glow OUTWARD without inflating the orb's box —
        // otherwise the frameless core Circle fills the halo's 2.5× frame and renders too big.
        ZStack {
            core
            rim
            glass
            gloss
            specular
        }
        .frame(width: size, height: size)
        .background {
            ZStack {
                halo
                if mode.ripples { ripples }
            }
            .frame(width: size, height: size)
        }
        .onAppear { restart() }
        .onChange(of: mode) { _, _ in restart() }
    }

    // soft outer glow that breathes — design: width size*2.5, glow@0.55·I → 0 at 62%, blur size*0.13
    private var halo: some View {
        Circle()
            .fill(RadialGradient(
                stops: [.init(color: mode.glow.opacity(0.46 * mode.intensity), location: 0),
                        .init(color: mode.glow.opacity(0), location: 0.62)],
                center: .center, startRadius: 0, endRadius: size * 1.25))
            .frame(width: size * 2.5, height: size * 2.5)
            .blur(radius: size * 0.15)
            .scaleEffect(haloPulse ? 1.08 : 1.0)
            .opacity(haloPulse ? 1.0 : 0.82)
            .allowsHitTesting(false)
    }

    // the incandescent ember — smooth glass sphere (design: gradient + subtle insets + twin outer glow)
    private var core: some View {
        Circle()
            // CSS `circle at 38% 30%` defaults to farthest-corner (~0.93·size) — the dark
            // end-stop must sit OUTSIDE the disc so the body reads as warm coral, not maroon.
            .fill(RadialGradient(stops: mode.coreStops,
                                 center: mode.coreCenter,
                                 startRadius: 0, endRadius: size * 0.93))
            // warm light, top-left interior  (design inset rgba(255,228,195,0.45))
            .overlay(
                Circle().fill(RadialGradient(
                    colors: [Color(hexv: 0xFFE4C3).opacity(0.40), .clear],
                    center: mode.coreCenter,
                    startRadius: 0, endRadius: size * 0.30))
                    .blendMode(.screen)
            )
            // warm inset glow at the bottom edge (design: inset 0 -0.06 0.12 glow) — lifts, not darkens
            .overlay(
                Circle().fill(RadialGradient(
                    colors: [mode.glow.opacity(0.50 * mode.intensity), .clear],
                    center: .bottom, startRadius: 0, endRadius: size * 0.58))
                    .blendMode(.screen)
            )
            .clipShape(Circle())
            .brightness(flick ? 0.12 : 0)
            .scaleEffect(pulse ? mode.coreScale : 1.0)
            // single twin-glow, matching the design's box-shadow on the glass shell
            .shadow(color: mode.glow.opacity(0.7 * mode.intensity), radius: size * 0.275)
            .shadow(color: mode.glow.opacity(0.4 * mode.intensity), radius: size * 0.575)
    }

    // refracted rim crescent at the bottom (light bending through the glass)
    private var rim: some View {
        Ellipse()
            .fill(RadialGradient(
                colors: [mode.glow.opacity(0.6 * mode.intensity), mode.glow.opacity(0)],
                center: .bottom, startRadius: 0, endRadius: size * 0.4))
            .frame(width: size * 0.72, height: size * 0.40)
            .blur(radius: size * 0.03)
            .offset(y: size * 0.23)
            .allowsHitTesting(false)
    }

    // the glass shell: bright top-left refraction + thin rim light (design: white 0.5→0.12→0 at 30% 22%)
    private var glass: some View {
        Circle()
            .fill(RadialGradient(
                stops: [.init(color: .white.opacity(0.50), location: 0),
                        .init(color: .white.opacity(0.12), location: 0.41),
                        .init(color: .white.opacity(0), location: 1)],
                center: UnitPoint(x: 0.30, y: 0.22),
                startRadius: 0, endRadius: size * 0.52))
            // bright glass rim catching light all the way around (design inset 0 0 0 1px rgba(255,235,220,0.18))
            .overlay(Circle().strokeBorder(Color(hexv: 0xffebdc).opacity(0.30), lineWidth: max(1, size * 0.008)))
            .allowsHitTesting(false)
    }

    // curved liquid highlight streak — design: w54% h34% at left16% top9%, white 0.85→0.25→0, rotate -12
    private var gloss: some View {
        Ellipse()
            .fill(LinearGradient(
                stops: [.init(color: .white.opacity(0.62), location: 0),
                        .init(color: Color(hexv: 0xfffaf2).opacity(0.18), location: 0.40),
                        .init(color: .white.opacity(0), location: 0.75)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size * 0.52, height: size * 0.28)
            .rotationEffect(.degrees(-12))
            .blur(radius: max(0.3, size * 0.012))
            .offset(x: -size * 0.07, y: -size * 0.24)
            .allowsHitTesting(false)
    }

    // small secondary specular dot — design: w9% h9% at right24% top20%
    private var specular: some View {
        Circle()
            .fill(RadialGradient(
                colors: [.white.opacity(0.9), .white.opacity(0)],
                center: .center, startRadius: 0, endRadius: size * 0.045))
            .frame(width: size * 0.09, height: size * 0.09)
            .offset(x: size * 0.215, y: -size * 0.255)
            .allowsHitTesting(false)
    }

    // expanding sound rings while speaking
    private var ripples: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .strokeBorder(mode.glow.opacity(0.5), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(ripple ? 2.0 : 0.5)
                    .opacity(ripple ? 0 : 0.55)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.8), value: ripple)
            }
        }
        .allowsHitTesting(false)
    }

    private func restart() {
        pulse = false; haloPulse = false; flick = false; ripple = false
        withAnimation(.easeInOut(duration: mode.coreDuration).repeatForever(autoreverses: true)) {
            pulse = true
        }
        withAnimation(.easeInOut(duration: mode.haloDuration).repeatForever(autoreverses: true)) {
            haloPulse = true
        }
        if mode.flickers {
            withAnimation(.easeInOut(duration: mode.coreDuration * 0.5).repeatForever(autoreverses: true)) {
                flick = true
            }
        }
        if mode.ripples {
            ripple = true
        }
    }
}
