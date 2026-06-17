import SwiftUI
import AppKit

/// Real macOS "liquid glass": an NSVisualEffectView blurs what's behind the window.
/// This is what `.ultraThinMaterial` over an opaque background can't do.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Makes the hosting window non-opaque so the behind-window blur shows through.
struct WindowGlassConfigurator: NSViewRepresentable {
    /// One-time so we don't fight the user resizing the window afterwards.
    static var sized = false
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ w: NSWindow?) {
        guard let w else { return }
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        // Force the design canvas (1440×920) once — macOS state-restoration otherwise
        // reopens the window at its last (cramped) saved frame, shrinking the layout.
        guard !Self.sized else { return }
        Self.sized = true
        w.setContentSize(NSSize(width: 1440, height: 920))
        w.center()
    }
}

extension View {
    /// Apple "Liquid Glass" surface: a translucent fill that frosts the warm window
    /// behind it, a bright top specular edge, a luminous warm rim, and a soft lift.
    func liquidGlass(corner: CGFloat = 16,
                     tint: Double = 0.05,
                     rim: Color = Color(hexv: 0xffaa78),
                     rimOpacity: Double = 0.16,
                     shadow: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return self
            // light glass body — brighter at the top, so the panel reads as a lit surface
            .background(
                LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.045)],
                               startPoint: .top, endPoint: .bottom), in: shape)
            .background(.ultraThinMaterial.opacity(0.35), in: shape)   // subtle frost texture
            .overlay(   // warm luminous rim
                shape.strokeBorder(rim.opacity(rimOpacity), lineWidth: 1)
            )
            .overlay(   // bright specular top edge
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0)],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1)
            )
            .clipShape(shape)
            .shadow(color: shadow ? .black.opacity(0.35) : .clear, radius: 14, y: 8)
    }
}
