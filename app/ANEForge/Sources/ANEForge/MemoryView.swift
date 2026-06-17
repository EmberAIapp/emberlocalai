import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var state: AppState
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 6)        // header margin-bottom:6px
                searchBar
                columns
            }
            .padding(.top, 34)
            .padding(.horizontal, 48)
            .padding(.bottom, 40)               // container padding 34px 48px 40px
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // gap:16px; align-items:center
    private var header: some View {
        HStack(spacing: 16) {
            EmberOrb(mode: state.orbMode, size: 40)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {   // subtitle margin-top:2px
                Text("Sa mémoire de toi")
                    .font(.emberSerif(30))               // Newsreader serif 30 / 600
                    .foregroundStyle(Color(hexv: 0xf5e7db))
                subtitle
            }
        }
    }

    // 14px · #9a8d84 (muted) + green #7fd095
    private var subtitle: some View {
        (
            Text("Tout est inspectable, modifiable, supprimable. ")
                .foregroundStyle(Color.emberMuted)
            + Text("Tu gardes la main.")
                .foregroundStyle(Color.localGreen2)
        )
        .font(.system(size: 14))
    }

    // gap:12px; margin:22px 0; padding:11px 16px; radius:14; bg .04 / border .08
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color(hexv: 0x8a7d75))
            Text("Rechercher un fait — « métier » trouve « boulanger » (sémantique multilingue)")
                .font(.system(size: 14))
                .foregroundStyle(Color(hexv: 0x8a7d75))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.vertical, 22)
    }

    // grid-template-columns:1.15fr 1fr; gap:26px.
    // layoutPriority controls allocation ORDER, not proportion — the old priority
    // starved the wiki card to a one-word-per-line sliver. Measure the row width and
    // split it 1.15 : 1 explicitly, sizing height to content.
    private var columns: some View {
        HStack(alignment: .top, spacing: 26) {
            MemoryFactsColumn()
                .frame(width: colWidth(1.15), alignment: .leading)
            MemoryWikiColumn()
                .frame(width: colWidth(1.0), alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { rowWidth = g.size.width }
                .onChange(of: g.size.width) { _, n in rowWidth = n }
        })
    }

    private func colWidth(_ fr: CGFloat) -> CGFloat {
        let avail = max(0, rowWidth - 26)
        return avail > 0 ? avail * fr / 2.15 : 0
    }
}

// MARK: - Faits column

private struct MemoryFactsColumn: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Faits · \(state.facts.count)")     // 11/700, tracking .8, #7c6f67
                .padding(.bottom, 13)                         // label margin-bottom:13px
            if state.facts.isEmpty {
                Text("Rien encore — apprends-lui des choses, ou discute.")
                    .font(.emberSerif(15, weight: .regular).italic())
                    .foregroundStyle(Color.emberMuted)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 9) {                          // facts list gap:9px
                    ForEach(state.facts) { fact in
                        MemoryFactRow(fact: fact)
                    }
                }
            }
            MemoryAddFactRow()
                .padding(.top, 12)                            // add-row margin-top:12px
        }
    }
}

private struct MemoryFactRow: View {
    @EnvironmentObject var state: AppState
    let fact: Fact
    @State private var hovering = false
    @State private var rowHover = false

    // Map a fact category to its own warm tone (design CAT palette).
    //   a perso/défaut → orange   bg rgba(255,150,90,0.14)  fg #e8b48f
    //   b projet       → bleu     bg rgba(120,170,255,0.14) fg #a9c4f0
    //   c goûts        → violet   bg rgba(180,130,255,0.14) fg #c9aef0
    //   d travail      → vert     bg rgba(95,208,122,0.12)  fg #9fd9ad
    private var pillColors: (fg: Color, bg: Color) {
        let k = fact.kind.lowercased()
        if k.contains("proj") || k.contains("goal") || k.contains("but") {
            return (Color(hexv: 0xa9c4f0), Color(hexv: 0x78aaff).opacity(0.14))   // bleu
        }
        if k.contains("goût") || k.contains("gout") || k.contains("like") || k.contains("aime") || k.contains("taste") {
            return (Color(hexv: 0xc9aef0), Color(hexv: 0xb482ff).opacity(0.14))   // violet
        }
        if k.contains("trav") || k.contains("job") || k.contains("work") || k.contains("métier") || k.contains("metier") {
            return (Color(hexv: 0x9fd9ad), Color(hexv: 0x5fd07a).opacity(0.12))   // vert
        }
        return (Color(hexv: 0xe8b48f), Color(hexv: 0xff965a).opacity(0.14))       // orange (perso/défaut)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {                 // gap:12px
            // category pill — 10/700, tracking .4, padding 4×8, radius 7, margin-top:1px
            TagPill(
                text: fact.kind.uppercased(),
                fg: pillColors.fg,
                bg: pillColors.bg,
                radius: 7, fontSize: 10, tracking: 0.4
            )
            .padding(.top, 1)
            Text(fact.text)                                    // 14px / line-height 1.45 / #e7d8cb
                .font(.system(size: 14))
                .foregroundStyle(Color(hexv: 0xe7d8cb))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            forgetButton
        }
        .padding(.vertical, 13)                                // padding:13px 15px
        .padding(.horizontal, 15)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)   // radius:13
                .fill(Color.white.opacity(rowHover ? 0.05 : 0.035))  // hover bg .05
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(rowHover ? Color(hexv: 0xffaa78).opacity(0.2)
                                 : Color.white.opacity(0.06), lineWidth: 1) // hover border
        )
        .onHover { rowHover = $0 }
    }

    // 24×24, radius 7, color #7c6f67 / font 15 ; hover bg rgba(255,90,70,0.15) color #ff8a7a
    private var forgetButton: some View {
        Button {
            Task { await state.forget(fact) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color(hexv: 0xff8a7a) : Color(hexv: 0x7c6f67))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color(hexv: 0xff5a46).opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// gap:10px; margin-top:12px; padding:11px 15px; radius:12; 1px dashed rgba(255,150,90,0.25); #c79a82; 13.5px
private struct MemoryAddFactRow: View {
    @State private var hovering = false

    var body: some View {
        Button {
        } label: {
            HStack(spacing: 10) {
                Text("+")
                    .font(.system(size: 15))
                Text("Ajouter un fait")
                    .font(.system(size: 13.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(hexv: 0xc79a82))
            .padding(.vertical, 11)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? Color(hexv: 0xff783c).opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        Color(hexv: 0xff965a).opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Wiki column

private struct MemoryWikiColumn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Wiki personnel · auto-maintenu")
                .padding(.bottom, 13)                 // label margin-bottom:13px
            MemoryWikiPanel()
            SectionLabel("Timeline")
                .padding(.top, 24)                    // margin:24px 0 13px
                .padding(.bottom, 13)
            MemoryTimeline()
        }
    }
}

private struct MemoryWikiPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // sources row — gap:8px; 11px; #8a7d75; margin-bottom:14px
            HStack(spacing: 8) {
                TagPill(
                    text: "raw/ 142 sources",
                    fg: Color(hexv: 0xaeb9e8),
                    bg: Color(hexv: 0x96aaff).opacity(0.12),
                    radius: 8, fontSize: 11
                )
                Text("→")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
                TagPill(
                    text: "wiki/ 12 pages",
                    fg: Color(hexv: 0xe8b48f),
                    bg: Color(hexv: 0xff965a).opacity(0.14),
                    radius: 8, fontSize: 11
                )
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)
            Text("Projet café-librairie")                 // serif 21 / 600 / #f3e3d7
                .font(.emberSerif(21))
                .foregroundStyle(Color(hexv: 0xf3e3d7))
            Text("Café-librairie à la Croix-Rousse avec coin torréfaction. Deux locaux étudiés rue de Belfort ; préférence pour celui avec cave voûtée (stockage des grains). Budget visé ~85 k€, ouverture envisagée printemps 2027.")
                .font(.emberSerif(15.5, weight: .regular))  // serif 15.5 / line-height 1.6 / #cdbcb0
                .foregroundStyle(Color(hexv: 0xcdbcb0))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)                          // margin-top:10px
            // footer — margin-top:14px; padding-top:13px; border-top rgba(255,255,255,0.07)
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.top, 14)
            footer
                .padding(.top, 13)
        }
        .padding(18)                                        // padding:18px
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()                                        // radius 18 / blur / warm border
    }

    // 11.5px #8a7d75 ; middle span #b09a8c
    private var footer: some View {
        (
            Text("Recoupé depuis : ")
                .foregroundStyle(Color(hexv: 0x8a7d75))
            + Text("Notes (3), Mail (2), conversation (5)")
                .foregroundStyle(Color(hexv: 0xb09a8c))
            + Text(" · maintenu par le modèle local")
                .foregroundStyle(Color(hexv: 0x8a7d75))
        )
        .font(.system(size: 11.5))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Timeline

private struct MemoryTimeline: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {            // flex-direction:column; gap:0
            ForEach(Array(DesignData.timeline.enumerated()), id: \.offset) { _, item in
                MemoryTimelineRow(item: item)
            }
        }
    }
}

private struct MemoryTimelineRow: View {
    let item: (text: String, when: String, dot: Color, last: Bool)

    var body: some View {
        HStack(alignment: .top, spacing: 14) {               // gap:14px
            VStack(spacing: 0) {
                Circle()
                    .fill(item.dot)
                    .frame(width: 9, height: 9)               // dot 9px
                    .shadow(color: item.dot, radius: 4)       // box-shadow 0 0 8px
                    .padding(.top, 5)                         // margin-top:5px
                if !item.last {
                    Rectangle()
                        .fill(Color(hexv: 0xffaa78).opacity(0.2))  // rgba(255,170,120,0.2)
                        .frame(width: 1.5)                    // line 1.5px
                        .frame(minHeight: 14, maxHeight: .infinity)
                }
            }
            .frame(width: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.text)                              // 13.5px / line-height 1.4 / #e7d8cb
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color(hexv: 0xe7d8cb))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.when)                              // 11px / #7c6f67 / margin-top:2px
                    .font(.system(size: 11))
                    .foregroundStyle(Color.emberFaint)
                    .padding(.top, 2)
            }
            .padding(.bottom, 16)                            // text block padding-bottom:16px
            Spacer(minLength: 0)
        }
    }
}
