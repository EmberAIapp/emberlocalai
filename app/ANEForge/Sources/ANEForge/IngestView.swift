import SwiftUI
import UniformTypeIdentifiers

struct IngestView: View {
    @EnvironmentObject var state: AppState
    @State private var isTargeted = false

    var body: some View {
        // container: padding 34px 48px 40px, overflow-y auto
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                dropzone
                    .padding(.top, 22)

                // CONNECTEURS LOCAUX · LECTURE SEULE — margin:30px 0 14px
                SectionLabel("Connecteurs locaux · lecture seule")
                    .padding(.top, 30)
                    .padding(.bottom, 14)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14),
                              GridItem(.flexible(), spacing: 14),
                              GridItem(.flexible(), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(DesignData.connectors) { c in
                        IngestConnectorCard(connector: c)
                    }
                }

                // SOURCES APPRISES + learn button — margin:32px 0 14px
                sourcesHeader
                    .padding(.top, 32)
                    .padding(.bottom, 14)

                if state.isLearning {
                    progressPanel
                        .padding(.bottom, 16)
                }

                sourcesList
            }
            .padding(.top, 34)
            .padding(.horizontal, 48)
            .padding(.bottom, 40)
        }
    }

    // <div style="display:flex;align-items:center;gap:16px;margin-bottom:8px;">
    private var header: some View {
        HStack(spacing: 16) {
            EmberOrb(mode: state.orbMode, size: 40)   // sectionOrb
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("Apprends-lui tes données")
                    .font(.emberSerif(30))                 // Newsreader serif 30 / 600
                    .tracking(0.2)                          // letter-spacing:0.2px
                    .foregroundStyle(Color(hexv: 0xf5e7db))
                IngestSubtitle()                            // margin-top:2px
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, 8)
    }

    // Dropzone: padding 42, radius 22, dashed border rgba(255,160,100,0.35), bg rgba(255,255,255,0.03)
    private var dropzone: some View {
        Button(action: openPicker) {
            VStack(spacing: 0) {
                // up-arrow svg: 44x44, stroke #e0a079, stroke-width 1.5
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color(hexv: 0xe0a079))
                Text("Glisse des fichiers ou dossiers ici")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xecd9c9))
                    .padding(.top, 14)                      // margin-top:14px
                Text(".txt · .md · .pdf — ou clique pour parcourir")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
                    .padding(.top, 5)                       // margin-top:5px
            }
            .frame(maxWidth: .infinity)
            .padding(42)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        dropBorderColor,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var dropBorderColor: Color {
        // hover → rgba(255,160,100,0.6); rest → rgba(255,160,100,0.35)
        isTargeted ? Color(hexv: 0xffa064).opacity(0.6) : Color(hexv: 0xffa064).opacity(0.35)
    }

    // SOURCES APPRISES (left) + learn button (right), space-between
    private var sourcesHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            SectionLabel("Sources apprises")
            Spacer()
            LearnButton(ingesting: state.isLearning, action: openPicker)
        }
    }

    // Apprentissage panel — padding 16px 18px, radius 14, bg rgba(255,120,60,0.08), border rgba(255,150,90,0.2)
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                EmberOrb(mode: .apprend, size: 18)          // miniOrb
                    .frame(width: 18, height: 18)
                Text("Apprentissage en cours…")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xe8c4a8))
                if let last = state.trainingLog.last {
                    Text(last)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(hexv: 0x8a7d75))
                        .lineLimit(1)
                }
            }
            // progress track — margin-top:11px, height 7, radius 6, bg rgba(0,0,0,0.3)
            IngestProgressBar()   // indeterminate — real training streams, we don't fake a %
                .padding(.top, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hexv: 0xff783c).opacity(0.08))   // rgba(255,120,60,0.08)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(hexv: 0xff965a).opacity(0.2), lineWidth: 1)  // rgba(255,150,90,0.2)
        )
    }

    // sources list — flex column gap 9px
    private var sourcesList: some View {
        VStack(spacing: 9) {
            ForEach(DesignData.sources(ingesting: state.isLearning)) { s in
                IngestSourceRow(source: s)
            }
        }
    }

    private func openPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, .text, .data]
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.teachFile(url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { await state.teachFile(url) }
        }
        return true
    }
}

// MARK: - Learn button (learnBtnStyle)
// font 12.5 / 700, padding 8px 16px, radius 20, color #1a0f0a, gradient 135deg #ffb877→#ff6024,
// shadow 0 6px 18px -6px rgba(255,90,40,0.6). Ingesting → bg rgba(255,255,255,0.12), no shadow.
private struct LearnButton: View {
    let ingesting: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(ingesting ? "Apprentissage…" : "✦ Apprendre (créer v4)")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(ingesting ? Color(hexv: 0xc79a82) : Color(hexv: 0x1a0f0a))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    if ingesting {
                        Capsule().fill(Color.white.opacity(0.12))
                    } else {
                        Capsule().fill(LinearGradient(
                            colors: [Color(hexv: 0xffb877), Color(hexv: 0xff6024)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .shadow(color: ingesting ? .clear : Color(hexv: 0xff5a28).opacity(0.6),
                        radius: 9, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(ingesting)
    }
}

// progress track interior — height 7, radius 6, bg rgba(0,0,0,0.3), gradient fill 90deg ffb877→ff6024
private struct IngestProgressBar: View {
    @State private var slide = false
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule().fill(.black.opacity(0.3))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hexv: 0xffb877), Color(hexv: 0xff6024)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * 0.34)
                        .offset(x: slide ? w * 0.66 : -w * 0.34)
                }
                .clipShape(Capsule())
        }
        .frame(height: 7)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { slide = true }
        }
    }
}

// Subtitle — 14px #9a8d84, with "Tout reste sur ce Mac." in #7fd095
private struct IngestSubtitle: View {
    var body: some View {
        (
            Text("Glisse tes fichiers ou connecte tes apps. ")
                .foregroundColor(.emberMuted)
            + Text("Tout reste sur ce Mac.")
                .foregroundColor(Color(hexv: 0x7fd095))
        )
        .font(.system(size: 14))
    }
}

// MARK: - Connector card
// padding 16, radius 16, bg rgba(255,255,255,0.04), border on→rgba(95,208,122,0.25)/off→rgba(255,255,255,0.07)
private struct IngestConnectorCard: View {
    let connector: Connector

    private var borderColor: Color {
        connector.connected ? Color(hexv: 0x5fd07a).opacity(0.25) : Color.white.opacity(0.07)
    }

    // pillStyle: font 10.5 / 600, padding 4px 10px, radius 10
    private var pillFg: Color {
        connector.connected ? Color(hexv: 0x9fd9ad) : Color(hexv: 0xc79a82)
    }
    private var pillBg: Color {
        connector.connected
            ? Color(hexv: 0x5fd07a).opacity(0.12)   // rgba(95,208,122,0.12)
            : Color(hexv: 0xff8c46).opacity(0.12)   // rgba(255,140,70,0.12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header row: icon tile + pill, space-between
            HStack(alignment: .center, spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(connector.iconBg)
                    Text(connector.icon)
                        .font(.system(size: 19))
                }
                .frame(width: 38, height: 38)
                Spacer()
                TagPill(
                    text: connector.connected ? "Connecté" : "Connecter",
                    fg: pillFg,
                    bg: pillBg
                )
            }
            // name — 15px / 600 #ecd9c9, margin-top:14px
            Text(connector.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hexv: 0xecd9c9))
                .padding(.top, 14)
            // desc — 12px #8a7d75, margin-top:3px
            Text(connector.desc)
                .font(.system(size: 12))
                .foregroundStyle(Color(hexv: 0x8a7d75))
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }
}

// MARK: - Learned source row
// gap 14, padding 13px 16px, radius 13, bg rgba(255,255,255,0.035), border rgba(255,255,255,0.06)
private struct IngestSourceRow: View {
    let source: LearnedSource

    // statusStyle: font 11 / 600, padding 4px 11px, radius 10
    private var pillFg: Color {
        source.ok ? Color(hexv: 0x9fd9ad) : Color(hexv: 0xc79a82)
    }
    private var pillBg: Color {
        source.ok
            ? Color(hexv: 0x5fd07a).opacity(0.10)   // rgba(95,208,122,0.1)
            : Color(hexv: 0xff8c46).opacity(0.10)   // rgba(255,140,70,0.1)
    }

    var body: some View {
        HStack(spacing: 14) {
            // icon tile — 34x34, radius 9, bg iconBg, font 15
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(source.iconBg)
                Text(source.icon)
                    .font(.system(size: 15))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(source.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xecd9c9))
                Text(source.meta)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
            }
            Spacer()
            TagPill(text: source.status, fg: pillFg, bg: pillBg, fontSize: 11)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
