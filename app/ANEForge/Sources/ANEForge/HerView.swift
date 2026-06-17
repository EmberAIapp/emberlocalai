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

    // top:22px; padding:0 30px; space-between
    private var topBar: some View {
        HStack {
            // gap:10px; font-size:12px; font-weight:700; letter-spacing:1px; color:#c79a82
            HStack(spacing: 10) {
                // 7px dot, #ff7a3a, box-shadow:0 0 10px #ff7a3a, emberPulse 1.6s
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
            // gap:8px; padding:8px 16px; border-radius:22px; bg rgba(255,255,255,0.06);
            // border rgba(255,255,255,0.12); color:#d8c6ba; 13px/600
            Button(action: { state.exitHer() }) {
                Text("Quitter ✕")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xd8c6ba))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 22)
        .padding(.horizontal, 30)
    }

    // flex:1; center; gap:64px; padding:0 60px
    private var centerContent: some View {
        HStack(spacing: 64) {
            HerLeftColumn()
            HerAgentPanel()
                .frame(width: 420)
        }
        .padding(.horizontal, 60)
    }
}

// MARK: - Orb + voice column

private struct HerLeftColumn: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // {{ herOrb }} → getOrb(mode, 240)
            EmberOrb(mode: state.orbMode, size: 240)
                .frame(width: 240, height: 240)

            // height:40px; margin-top:34px
            HerWaveform()
                .padding(.top, 34)

            // margin-top:24px; Newsreader italic 21px; #d8b9a6; max-width:380; line-height:1.4
            Text(DesignData.herTranscript)
                .font(.emberSerif(21, weight: .regular).italic())
                .foregroundStyle(Color(hexv: 0xd8b9a6))
                .multilineTextAlignment(.center)
                .lineSpacing(21 * 0.4)
                .frame(maxWidth: 380)
                .padding(.top, 24)
        }
    }
}

// MARK: - Waveform — 11 bars, 5px×40px, gradient #ffb877→#ff6024, animated

private struct HerWaveform: View {
    @State private var animate = false
    private let count = 11

    var body: some View {
        // align-items:flex-end; gap:5px; height:40px
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        // linear-gradient(180deg,#ffb877,#ff6024)
                        LinearGradient(
                            colors: [Color(hexv: 0xffb877), Color(hexv: 0xff6024)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 5, height: 40)
                    .scaleEffect(y: animate ? 1.0 : 0.25, anchor: .bottom)
                    // animation: 'wave ' + (0.7 + (i % 4) * 0.18) + 's ' + (i * 0.08) + 's infinite'
                    .animation(
                        .easeInOut(duration: 0.7 + Double(i % 4) * 0.18)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.08),
                        value: animate
                    )
            }
        }
        .frame(height: 40)
        .onAppear { animate = true }
    }
}

// MARK: - Agent orchestration panel

private struct HerAgentPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // padding:24px; border-radius:22px; glass
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)

            // gap:5px
            VStack(spacing: 5) {
                ForEach(Array(DesignData.agentSteps.enumerated()), id: \.offset) { idx, step in
                    HerAgentRow(index: idx, step: step)
                }
            }

            // margin-top:16px; padding-top:14px; border-top rgba(255,255,255,0.08)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 16)

            controls
                .padding(.top, 14)

            footer
                .padding(.top, 12)
        }
        .padding(24)
        .glassCard(corner: 22)
    }

    // space-between; margin-bottom:18px (applied above)
    private var header: some View {
        HStack {
            // 13px/700; letter-spacing:0.5px; #f0ddcf
            Text("Agents au travail")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Color(hexv: 0xf0ddcf))
            Spacer()
            // 11px; #9a8d84; bg rgba(255,255,255,0.06); padding:3px 9px; radius:9
            Text("orchestration locale")
                .font(.system(size: 11))
                .foregroundStyle(Color.emberMuted)
                .padding(.vertical, 3)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06))
                )
        }
    }

    // gap:10px
    private var controls: some View {
        HStack(spacing: 10) {
            // flex:1; 12.5px/600; padding:9px; radius:12; #e8d4c6; bg rgba(255,255,255,0.06); border rgba(255,255,255,0.1)
            Button(action: { state.toggleAgentPause() }) {
                Text(state.agentPaused ? "Reprendre" : "Mettre en pause")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xe8d4c6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            // flex:1; 12.5px/600; padding:9px; radius:12; #d8b3a3; bg rgba(255,90,70,0.1); border rgba(255,90,70,0.18)
            Button(action: { state.stopAgent() }) {
                Text("Tout arrêter")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xd8b3a3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12).fill(Color(hexv: 0xff5a46).opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hexv: 0xff5a46).opacity(0.18), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // gap:9px; 11px; #9bbfa3
    private var footer: some View {
        HStack(spacing: 9) {
            // 13×13 shield, stroke #7fd095
            Image(systemName: "checkmark.shield")
                .font(.system(size: 13))
                .foregroundStyle(Color(hexv: 0x7fd095))
            Text("Rien sans ta permission · 100% local")
                .font(.system(size: 11))
                .foregroundStyle(Color(hexv: 0x9bbfa3))
        }
    }
}

// MARK: - A single agent step row

private struct HerAgentRow: View {
    @EnvironmentObject var state: AppState
    let index: Int
    let step: DesignData.AgentStep

    private var stepState: AppState.StepState { state.agentStepState(index) }

    // herBg: doing → rgba(255,120,60,0.08); gate → rgba(255,200,80,0.07); else transparent
    private var rowBackground: Color {
        switch stepState {
        case .doing: return Color(hexv: 0xff783c).opacity(0.08)
        case .gate:  return Color(hexv: 0xffc850).opacity(0.07)
        default:     return Color.clear
        }
    }

    var body: some View {
        // align-items:center; gap:12px; padding:9px 9px; radius:12
        HStack(spacing: 12) {
            StepMark(state: stepState)

            // flex:1; min-width:0
            VStack(alignment: .leading, spacing: 0) {
                // 13px/600; color textColor
                Text(step.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(stepState.textColor)
                // 11px; #9a8d84
                Text(step.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.emberMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingContent
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(rowBackground)
        )
    }

    // gate → Allow/Deny buttons; else → status span (right-aligned siblings in the row)
    @ViewBuilder
    private var trailingContent: some View {
        if stepState == .gate {
            // gap:6px
            HStack(spacing: 6) {
                // 11.5px/600; padding:5px 12px; radius:13; color:#1a0f0a; gradient 135deg #ffb877,#ff7a3a
                Button(action: { state.resolveGate(true) }) {
                    Text("Autoriser")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(hexv: 0x1a0f0a))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 13).fill(
                                LinearGradient(
                                    colors: [Color(hexv: 0xffb877), Color(hexv: 0xff7a3a)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )
                }
                .buttonStyle(.plain)

                // 11.5px/500; padding:5px 12px; radius:13; color:#b09a8c; border rgba(255,255,255,0.14)
                Button(action: { state.resolveGate(false) }) {
                    Text("Refuser")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color(hexv: 0xb09a8c))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        } else if stepState.showsStatus {
            // 11px; #8a7d75
            Text(stepState.statusText)
                .font(.system(size: 11))
                .foregroundStyle(Color(hexv: 0x8a7d75))
        }
    }
}
