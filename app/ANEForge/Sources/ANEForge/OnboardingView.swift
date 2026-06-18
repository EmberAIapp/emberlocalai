import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var name: String = "My Ember"
    @State private var personaSel: String = "Calm"

    var body: some View {
        ZStack {
            // background: radial-gradient(120% 100% at 50% 30%, rgba(40,24,18,0.96), rgba(10,6,5,0.98)) + blur(20)
            OnboardingBackground()

            VStack(spacing: 0) {
                // Step body
                EmberOrb(mode: orbMode, size: 150)
                    .frame(height: 240)

                // title — Newsreader serif 34 / 600 / #f5e7db / letter-spacing 0.2 / max-width 560
                Text(title)
                    .font(.emberSerif(34, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(Color(hexv: 0xf5e7db))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)

                // sub — 15.5 / #a99a8f / margin-top 10 / max-width 480 / line-height 1.5
                Text(subtitle)
                    .font(.system(size: 15.5))
                    .foregroundStyle(Color(hexv: 0xa99a8f))
                    .multilineTextAlignment(.center)
                    .lineSpacing(15.5 * 0.5)
                    .frame(maxWidth: 480)
                    .padding(.top, 10)

                // Step body — margin-top 30 / width 480 / min-height 96 / centered
                stepBody
                    .frame(width: 480)
                    .frame(minHeight: 96)
                    .padding(.top, 30)

                // Progress dots — gap 10 / margin-top 34
                progressDots
                    .padding(.top, 34)

                // CTA — margin-top 26
                onboardCTA
                    .padding(.top, 26)
            }
            // "Passer" — top 26 / right 30 / 13 / #8a7d75
            .overlay(alignment: .topTrailing) {
                Button(action: { state.skipOnboard() }) {
                    Text("Skip")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hexv: 0x8a7d75))
                }
                .buttonStyle(.plain)
                .padding(.top, 26)
                .padding(.trailing, 30)
            }
        }
    }

    private var orbMode: OrbMode {
        switch state.onboardStep {
        case 1: return .ecoute
        case 2: return .apprend
        default: return .parle
        }
    }

    private var title: String {
        switch state.onboardStep {
        case 1: return "Give her a name"
        case 2: return "Teach her your data"
        default: return "She knows you now"
        }
    }

    private var subtitle: String {
        switch state.onboardStep {
        case 1: return "And choose her temperament. You can change everything later."
        case 2: return "Drop in whatever you want her to know. Nothing leaves this Mac."
        default: return "Talk to her. Her memory is yours — inspectable and private."
        }
    }

    private var ctaTitle: String {
        if state.onboardStep == 2 && state.isLearning { return "Learning…" }
        return state.onboardStep == 3 ? "Get started" : "Continue"
    }

    @ViewBuilder
    private var stepBody: some View {
        switch state.onboardStep {
        case 1: OnboardingStepName(name: $name, personaSel: $personaSel)
        case 2: OnboardingStepLearn()
        default: OnboardingStepChat()
        }
    }

    // gap 10
    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(1...3, id: \.self) { idx in
                OnboardingDot(active: idx == state.onboardStep)
            }
        }
    }

    // padding 14px 44px / border-radius 28 / 15 / 700 / #1a0f0a / gradient 135deg #ffb877→#ff6024
    private var onboardCTA: some View {
        Button(action: advance) {
            Text(ctaTitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(hexv: 0x1a0f0a))
                .padding(.horizontal, 44)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color(hexv: 0xffb877), Color(hexv: 0xff6024)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 28))
                // inset 0 1px 0 rgba(255,255,255,0.4)
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                        .blendMode(.overlay)
                )
                // 0 12px 32px -8px rgba(255,90,40,0.6)
                .shadow(color: Color(hexv: 0xff5a28).opacity(0.6), radius: 16, y: 12)
        }
        .buttonStyle(.plain)
    }

    private func advance() {
        if state.onboardStep == 1 {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if state.models.isEmpty && !trimmed.isEmpty {
                Task { await state.create(name: trimmed, base: "qwen2.5-1.5b-instruct") }
            }
        }
        state.onboardNext()
    }
}

// background: radial-gradient(120% 100% at 50% 30%, rgba(40,24,18,0.96), rgba(10,6,5,0.98)); backdrop-filter: blur(20px)
private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            RadialGradient(
                stops: [
                    .init(color: Color(hexv: 0x281812).opacity(0.96), location: 0),
                    .init(color: Color(hexv: 0x0a0605).opacity(0.98), location: 1.0)
                ],
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadius: 0,
                endRadius: 920
            )
        }
        .ignoresSafeArea()
    }
}

// width active 22 else 8 / height 8 / border-radius 5 / gradient 90deg #ffb877→#ff6024 else rgba(255,255,255,0.18)
private struct OnboardingDot: View {
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(dotFill)
            .frame(width: active ? 22 : 8, height: 8)
            .animation(.easeInOut(duration: 0.3), value: active)
    }

    private var dotFill: AnyShapeStyle {
        if active {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(hexv: 0xffb877), Color(hexv: 0xff6024)],
                startPoint: .leading,
                endPoint: .trailing))
        } else {
            return AnyShapeStyle(Color.white.opacity(0.18))
        }
    }
}

// Step 1 — name field + persona chips
private struct OnboardingStepName: View {
    @Binding var name: String
    @Binding var personaSel: String

    var body: some View {
        VStack(spacing: 14) {
            // padding 5 5 5 20 / radius 18 / bg rgba(255,255,255,0.06) / border rgba(255,170,120,0.2)
            HStack(spacing: 0) {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.emberSerif(20, weight: .regular))
                    .foregroundStyle(Color(hexv: 0xf3e3d7))

                Text("her name")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
                    .padding(.trailing, 10)
            }
            .padding(.leading, 20)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color(hexv: 0xffaa78).opacity(0.2), lineWidth: 1)
            )
            // inset 0 1px 0 rgba(255,255,255,0.08)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.clear)
                    .frame(height: 1)
                    .overlay(Color.white.opacity(0.08).frame(height: 1))
                    .padding(.horizontal, 1)
                    .allowsHitTesting(false)
            }

            personaChips
        }
    }

    // gap 9 / justify center / wrap
    private var personaChips: some View {
        HStack(spacing: 9) {
            ForEach(DesignData.personaOptions, id: \.self) { opt in
                OnboardingPersonaChip(
                    label: opt,
                    selected: opt == personaSel,
                    action: { personaSel = opt }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// font 13 / weight sel 600 else 500 / padding 8 17 / radius 20 / colors per spec
private struct OnboardingPersonaChip: View {
    let label: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color(hexv: 0x1a0f0a) : Color(hexv: 0xb09a8c))
                .padding(.horizontal, 17)
                .padding(.vertical, 8)
                .background {
                    if selected {
                        Capsule().fill(LinearGradient(
                            colors: [Color(hexv: 0xffb877), Color(hexv: 0xff7a3a)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        Capsule().fill(Color.white.opacity(0.05))
                    }
                }
                .overlay(
                    Capsule().strokeBorder(
                        selected ? Color(hexv: 0xffa064).opacity(0.5) : Color.white.opacity(0.1),
                        lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// Step 2 — dropzone. padding 30 / radius 18 / 1.5px dashed rgba(255,160,100,0.4) / bg rgba(255,255,255,0.04)
private struct OnboardingStepLearn: View {
    var body: some View {
        VStack(spacing: 0) {
            // svg arrow-up, 34, stroke #e0a079, stroke-width 1.5
            Image(systemName: "arrow.up")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color(hexv: 0xe0a079))
                .frame(width: 34, height: 34)

            // 15 / 600 / #ecd9c9 / margin-top 12
            Text("Drop in a note, a PDF, a folder…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hexv: 0xecd9c9))
                .padding(.top, 12)

            // 12.5 / #8a7d75 / margin-top 4
            Text("or connect Notes, Mail, Obsidian")
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hexv: 0x8a7d75))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    Color(hexv: 0xffa064).opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        )
        .contentShape(Rectangle())
    }
}

// Step 3 — quote. Newsreader italic 19 / #cdbcb0 / line-height 1.5
private struct OnboardingStepChat: View {
    var body: some View {
        Text("“Ask me anything about you.\nI'll remember it, and nothing will leave this Mac.”")
            .font(.emberSerif(19, weight: .regular).italic())
            .foregroundStyle(Color(hexv: 0xcdbcb0))
            .multilineTextAlignment(.center)
            .lineSpacing(19 * 0.5)
            .frame(maxWidth: .infinity)
    }
}
