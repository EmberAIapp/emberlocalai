import SwiftUI

// Ember brand palette — matches the website (warm, dark, ember).
extension Color {
    init(hexv: UInt) {
        self.init(.sRGB,
                  red: Double((hexv >> 16) & 0xff) / 255,
                  green: Double((hexv >> 8) & 0xff) / 255,
                  blue: Double(hexv & 0xff) / 255,
                  opacity: 1)
    }
}

// Exposed on ShapeStyle so the leading-dot form works in .foregroundStyle/.fill,
// and also usable explicitly as Color.emberBg etc.
extension ShapeStyle where Self == Color {
    static var emberBg: Color    { Color(hexv: 0x0b0907) }
    static var emberBg2: Color   { Color(hexv: 0x120d0a) }
    static var emberInk: Color   { Color(hexv: 0xf6efe6) }
    static var emberMuted: Color { Color(hexv: 0xa99c8d) }
    static var emberFaint: Color { Color(hexv: 0x6f6356) }
    static var ember1: Color     { Color(hexv: 0xffb061) }
    static var ember2: Color     { Color(hexv: 0xff7a3c) }
    static var ember3: Color     { Color(hexv: 0xe8431a) }
}

/// The Ember "bulle" — a glowing ember that breathes, and flares hotter when active.
struct EmberOrb: View {
    var size: CGFloat = 84
    var active: Bool = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            // soft outer glow
            Circle()
                .fill(RadialGradient(
                    colors: [Color.ember2.opacity(active ? 0.55 : 0.32),
                             Color.ember3.opacity(0.14), .clear],
                    center: .center, startRadius: 2, endRadius: size * 0.95))
                .frame(width: size * 2.1, height: size * 2.1)
                .scaleEffect(breathe ? 1.08 : 0.94)
            // incandescent core
            Circle()
                .fill(RadialGradient(
                    colors: [Color(hexv: 0xfff4e6), .ember1, .ember3],
                    center: UnitPoint(x: 0.40, y: 0.34),
                    startRadius: 1, endRadius: size * 0.62))
                .frame(width: size, height: size)
                .shadow(color: .ember2.opacity(active ? 0.9 : 0.55),
                        radius: active ? 34 : 18)
                .shadow(color: .ember3.opacity(active ? 0.6 : 0.0), radius: 50)
                .scaleEffect(breathe ? (active ? 1.10 : 1.04) : 1.0)
        }
        .animation(.easeInOut(duration: 0.5), value: active)
        .onAppear {
            withAnimation(.easeInOut(duration: active ? 1.1 : 3.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}
