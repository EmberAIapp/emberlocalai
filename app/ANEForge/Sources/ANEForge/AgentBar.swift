import SwiftUI

/// "Le fil" — the agent control bar that floats at the bottom of the work screens.
/// Pixel-matched to the Ember.dc design (spec_agentbar.html + spec_agentidle.html).
/// Visual layer only — all agent wiring (start/pause/stop/expand/gate, steps, progress)
/// is driven by AppState exactly as before.
struct AgentFil: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.agentRunning {
                runningBar
            } else {
                idle
            }
        }
        // Spec container: width:560px; max-width:82%; centered, bottom:24px (parent owns the offset).
        .frame(maxWidth: 560)
    }

    // MARK: - Idle pill (spec_agentidle.html)
    // right:24px;bottom:24px; gap:9px; padding:9px 15px; border-radius:24px;
    // background:rgba(26,17,14,0.72); blur(30); border:1px solid rgba(255,255,255,0.1);
    // color:#9a8d84; font-size:12.5px. Dot: 7px #5a463c. (Bottom-right of the work area.)
    private var idle: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: { state.startAgent() }) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Color(hexv: 0x5a463c))
                        .frame(width: 7, height: 7)
                    Text("Ember en veille — confier une tâche")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.emberMuted)               // #9a8d84
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 15)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(hexv: 0x1a110e).opacity(0.72))
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(.ultraThinMaterial)                 // backdrop-filter: blur(30px)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)   // border rgba(255,255,255,0.1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Running stack: expanded steps panel (above) + collapsed bar
    private var runningBar: some View {
        VStack(spacing: 10) {                                            // margin-bottom:10px on the panel
            if state.agentExpanded {
                AgentFilExpandedPanel()
            }
            AgentFilBar()
        }
    }
}

// MARK: - Expanded steps panel
// padding:13px 16px; border-radius:18px; background:rgba(26,17,14,0.82);
// blur(40) saturate(170%); border:1px solid rgba(255,220,200,0.12);
// box-shadow:0 26px 64px -18px rgba(0,0,0,0.66).
private struct AgentFilExpandedPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Steps list (display:flex;flex-direction:column;)
            ForEach(Array(DesignData.agentSteps.enumerated()), id: \.offset) { pair in
                AgentFilStepRow(index: pair.offset)
            }

            // Footer: margin-top:5px;padding-top:10px;border-top:1px solid rgba(255,255,255,0.07);
            //         font-size:10.5px;color:#7c6f67; gap:7px; shield ✔ #7fd095.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.top, 5)                                    // margin-top:5px

                HStack(spacing: 7) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hexv: 0x7fd095))
                    Text("Tout reste sur ce Mac · pause ou arrêt à tout instant")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.emberFaint)               // #7c6f67
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)                                       // padding-top:10px
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hexv: 0x1a110e).opacity(0.82))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)                        // blur(40) saturate(170%)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(hexv: 0xffdcc8).opacity(0.12), lineWidth: 1) // rgba(255,220,200,0.12)
        )
        .shadow(color: Color.black.opacity(0.66), radius: 32, x: 0, y: 26) // 0 26px 64px -18px rgba(0,0,0,0.66)
    }
}

// MARK: - Step row
// display:flex;align-items:center;gap:13px;padding:8px 3px;
// text: font-size:13px;color:{{ st.textColor }}; flex:1; min-width:0.
private struct AgentFilStepRow: View {
    @EnvironmentObject var state: AppState
    let index: Int

    private var step: DesignData.AgentStep { DesignData.agentSteps[index] }
    private var stepState: AppState.StepState { state.agentStepState(index) }

    var body: some View {
        HStack(spacing: 13) {
            StepMark(state: stepState)                                   // shared 18px mark
            Text(step.text)
                .font(.system(size: 13))
                .foregroundStyle(stepState.textColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 8)                                           // padding: 8px (vertical)
        .padding(.horizontal, 3)                                         //          3px (horizontal)
    }

    // gate buttons (Autoriser / Refuser) or a status label.
    @ViewBuilder
    private var trailing: some View {
        if stepState == .gate {
            // display:flex;gap:7px;
            HStack(spacing: 7) {
                // Autoriser: font-size:12;font-weight:600;padding:5px 13px;border-radius:14px;
                //            color:#1a0f0a; background:linear-gradient(135deg,#ffb877,#ff7a3a).
                Button(action: { state.resolveGate(true) }) {
                    Text("Autoriser")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hexv: 0x1a0f0a))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(colors: [Color(hexv: 0xffb877), Color(hexv: 0xff7a3a)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                }
                .buttonStyle(.plain)

                // Refuser: font-size:12;font-weight:500;padding:5px 13px;border-radius:14px;
                //          color:#b09a8c; background:transparent; border:1px solid rgba(255,255,255,0.13).
                Button(action: { state.resolveGate(false) }) {
                    Text("Refuser")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hexv: 0xb09a8c))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 13)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.13), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        } else if stepState.showsStatus {
            // <span style="font-size:11px;color:#8a7d75;">{{ st.status }}</span>
            Text(stepState.statusText)
                .font(.system(size: 11))
                .foregroundStyle(Color(hexv: 0x8a7d75))
        }
    }
}

// MARK: - Collapsed control bar
// display:flex;align-items:center;gap:11px;padding:9px 10px 9px 13px;border-radius:30px;
// background:rgba(26,17,14,0.76); blur(40) saturate(170%);
// border:1px solid rgba(255,220,200,0.13);
// box-shadow:0 16px 40px -12px rgba(0,0,0,0.55), inset 0 1px 0 rgba(255,255,255,0.07).
private struct AgentFilBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 11) {
            // {{ agentBarOrb }} = getOrb(paused ? 'repos' : 'reflexion', 22)  — flex:0 0 auto.
            EmberOrb(mode: state.agentPaused ? .repos : .reflexion, size: 22)
                .frame(width: 22, height: 22)

            // text block (flex:1; min-width:0)
            VStack(alignment: .leading, spacing: 0) {
                // font-size:12.5px;font-weight:600;color:#ecd9c9; single line w/ ellipsis.
                Text(state.agentBarText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xecd9c9))              // #ecd9c9
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // margin-top:5px;height:2px;border-radius:2px;background:rgba(255,255,255,0.08).
                AgentFilProgressTrack()
                    .padding(.top, 5)
            }

            // Round controls — pause / stop / expand (gap:7px effectively via spacing here).
            HStack(spacing: 0) {
                // Pause: font-size:11px;letter-spacing:-1px;color:#c9bbb1.
                AgentFilRoundButton(
                    glyph: state.agentPaused ? "▶" : "❙❙",
                    fontSize: 11,
                    tracking: -1,
                    baseColor: Color(hexv: 0xc9bbb1),
                    hoverColor: Color(hexv: 0xc9bbb1),
                    hoverBg: Color.white.opacity(0.06),
                    action: { state.toggleAgentPause() }
                )
                // Stop: font-size:13px;color:#9a8d84; hover #ff8a7a over rgba(255,90,70,0.14).
                AgentFilRoundButton(
                    glyph: "✕",
                    fontSize: 13,
                    baseColor: Color(hexv: 0x9a8d84),
                    hoverColor: Color(hexv: 0xff8a7a),
                    hoverBg: Color(hexv: 0xff5a46).opacity(0.14),
                    action: { state.stopAgent() }
                )
                // Expand chevron: font-size:13px;color:#9a8d84; hover #c9bbb1 over rgba(255,255,255,0.06).
                AgentFilRoundButton(
                    glyph: state.agentExpanded ? "⌄" : "⌃",
                    fontSize: 13,
                    baseColor: Color(hexv: 0x9a8d84),
                    hoverColor: Color(hexv: 0xc9bbb1),
                    hoverBg: Color.white.opacity(0.06),
                    action: { state.toggleAgentExpand() }
                )
            }
        }
        .padding(.leading, 13)                                          // padding-left:13px
        .padding(.trailing, 10)                                         // padding-right:10px
        .padding(.vertical, 9)                                          // padding top/bottom:9px
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(hexv: 0x1a110e).opacity(0.76))
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)                        // blur(40) saturate(170%)
                )
        )
        .overlay(
            // border 1px rgba(255,220,200,0.13)
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color(hexv: 0xffdcc8).opacity(0.13), lineWidth: 1)
        )
        .overlay(
            // inset 0 1px 0 rgba(255,255,255,0.07) — top inner highlight
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                .mask(
                    LinearGradient(colors: [.white, .clear],
                                   startPoint: .top, endPoint: .center)
                )
        )
        .shadow(color: Color.black.opacity(0.55), radius: 20, x: 0, y: 16) // 0 16px 40px -12px rgba(0,0,0,0.55)
    }
}

// MARK: - Progress track (2px) — shimmer while working, solid fill otherwise.
// background:rgba(255,255,255,0.08); shimmer width 32% gradient #ff965a; or
// finished -> rgba(95,208,122,0.6); else -> rgba(255,150,90,0.5) filled to {{ pct }}%.
private struct AgentFilProgressTrack: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                if state.agentWorking {
                    AgentFilShimmer(width: geo.size.width)
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            state.agentFinished
                                ? Color(hexv: 0x5fd07a).opacity(0.6)     // rgba(95,208,122,0.6)
                                : Color(hexv: 0xff965a).opacity(0.5)     // rgba(255,150,90,0.5)
                        )
                        .frame(width: max(0, min(1, state.agentProgress)) * geo.size.width)
                }
            }
        }
        .frame(height: 2)                                               // height:2px
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

// MARK: - Shimmer: 32% wide gradient sweeping across, 1.5s linear loop.
// background:linear-gradient(90deg,transparent,rgba(255,150,90,0.95),transparent).
private struct AgentFilShimmer: View {
    let width: CGFloat
    @State private var animate = false

    private var barWidth: CGFloat { width * 0.32 }                      // width:32%

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(hexv: 0xff965a).opacity(0.95),            // rgba(255,150,90,0.95)
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: barWidth)
            .offset(x: animate ? (width - barWidth) : 0)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}

// MARK: - Round control button (30x30 circle, hover highlight).
private struct AgentFilRoundButton: View {
    let glyph: String
    var fontSize: CGFloat = 13
    var tracking: CGFloat = 0
    let baseColor: Color
    let hoverColor: Color
    let hoverBg: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: fontSize, weight: .medium))
                .tracking(tracking)
                .foregroundStyle(hover ? hoverColor : baseColor)
                .frame(width: 30, height: 30)                           // 30x30
                .background(Circle().fill(hover ? hoverBg : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
