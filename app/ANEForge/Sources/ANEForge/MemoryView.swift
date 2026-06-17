import SwiftUI

// MARK: - Fact metadata helpers (§4.D : catégories, sources, timeline)

/// "il y a 5 min", "hier"… from the stored ISO date (locale-aware). Empty if unparseable.
func factRelativeDate(_ iso: String?) -> String {
    guard let iso, !iso.isEmpty else { return "" }
    let p1 = ISO8601DateFormatter(); p1.formatOptions = [.withInternetDateTime]
    let p2 = ISO8601DateFormatter(); p2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let d = p1.date(from: iso) ?? p2.date(from: iso) else { return "" }
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; f.locale = .current
    return f.localizedString(for: d, relativeTo: Date())
}

/// Human category label for a fact's kind (works for any classify_kind output).
func factCategoryLabel(_ kind: String) -> String {
    let k = kind.lowercased()
    if k.contains("trav") || k.contains("job") || k.contains("work") || k.contains("méti") || k.contains("meti") { return "TRAVAIL" }
    if k.contains("proj") || k.contains("goal") || k.contains("but") { return "PROJET" }
    if k.contains("goût") || k.contains("gout") || k.contains("like") || k.contains("aime") || k.contains("taste") { return "GOÛTS" }
    if k.contains("lieu") || k.contains("loc") { return "LIEU" }
    if k.contains("rel") || k.contains("ami") || k.contains("famille") { return "PROCHES" }
    if k.contains("perso") || k.contains("name") || k.contains("nom") { return "PERSO" }
    return "DIVERS"
}

/// Where a fact came from → (label, SF Symbol). nil for unknown sources.
func factSource(_ source: String) -> (text: String, icon: String)? {
    switch source {
    case "explicit": return ("ajouté par toi", "pencil")
    case "model":    return ("appris en discutant", "bubble.left.fill")
    case "idle":     return ("noté en veille", "moon.fill")
    case "file":     return ("depuis un fichier", "doc.fill")
    default:         return nil
    }
}

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
        // Reload facts whenever this screen appears or the selected IA changes — otherwise
        // facts learned during a chat don't show until something else refreshes them.
        .task(id: state.selected?.name) {
            if let n = state.selected?.name { await state.loadFacts(n) }
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
    // REAL search: a TextField bound to state.factQuery, debounced → semantic search (§4).
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color(hexv: 0x8a7d75))
            TextField("", text: $state.factQuery, prompt:
                Text("Rechercher un fait — « métier » trouve « infirmière » (sémantique multilingue)")
                    .foregroundColor(Color(hexv: 0x8a7d75)))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Color(hexv: 0xe7d8cb))
            if state.searching {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            if !state.factQuery.isEmpty {
                Button { state.factQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hexv: 0x8a7d75))
                }
                .buttonStyle(.plain)
            }
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
        // Debounce: rerun on every keystroke, but wait ~280ms; .task(id:) cancels the
        // previous (pending) search when the query changes again.
        .task(id: state.factQuery) {
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            await state.runSearch(state.factQuery)
        }
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
        let querying = !state.factQuery.trimmingCharacters(in: .whitespaces).isEmpty
        let shown = state.visibleFacts
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(querying ? "Résultats · \(shown.count)"
                                  : "Faits · \(state.facts.count)")   // 11/700, tracking .8
                .padding(.bottom, 13)                         // label margin-bottom:13px
            if shown.isEmpty {
                Text(querying ? "Aucun fait ne correspond à « \(state.factQuery) »."
                              : "Rien encore — apprends-lui des choses, ou discute.")
                    .font(.emberSerif(15, weight: .regular).italic())
                    .foregroundStyle(Color.emberMuted)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 9) {                          // facts list gap:9px
                    ForEach(shown) { fact in
                        MemoryFactRow(fact: fact)
                    }
                }
            }
            if !querying {                                    // no manual-add while filtering
                MemoryAddFactRow()
                    .padding(.top, 12)                        // add-row margin-top:12px
            }
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
            return (Color(hexv: 0xa9c4f0), Color(hexv: 0x78aaff).opacity(0.14))   // bleu — projet
        }
        if k.contains("goût") || k.contains("gout") || k.contains("like") || k.contains("aime") || k.contains("taste") {
            return (Color(hexv: 0xc9aef0), Color(hexv: 0xb482ff).opacity(0.14))   // violet — goûts
        }
        if k.contains("trav") || k.contains("job") || k.contains("work") || k.contains("méti") || k.contains("meti") {
            return (Color(hexv: 0x9fd9ad), Color(hexv: 0x5fd07a).opacity(0.12))   // vert — travail
        }
        if k.contains("lieu") || k.contains("loc") {
            return (Color(hexv: 0x8fd9d0), Color(hexv: 0x5fd0c0).opacity(0.13))   // teal — lieu
        }
        if k.contains("rel") || k.contains("ami") || k.contains("famille") {
            return (Color(hexv: 0xf0a9c4), Color(hexv: 0xff78aa).opacity(0.13))   // rose — proches
        }
        return (Color(hexv: 0xe8b48f), Color(hexv: 0xff965a).opacity(0.14))       // orange — perso/divers
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {                 // gap:12px
            // category pill — 10/700, tracking .4, padding 4×8, radius 7, margin-top:1px
            TagPill(
                text: factCategoryLabel(fact.kind),
                fg: pillColors.fg,
                bg: pillColors.bg,
                radius: 7, fontSize: 10, tracking: 0.4
            )
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(fact.text)                                // 14px / line-height 1.45 / #e7d8cb
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hexv: 0xe7d8cb))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                metaLine                                       // source · quand (§4.D)
            }
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

    // source · quand — small muted subtitle under the fact (sources + timeline, §4.D)
    @ViewBuilder private var metaLine: some View {
        let src = factSource(fact.source)
        let when = factRelativeDate(fact.createdAt)
        if src != nil || !when.isEmpty {
            HStack(spacing: 5) {
                if let src {
                    Image(systemName: src.icon).font(.system(size: 9))
                    Text(src.text)
                }
                if src != nil && !when.isEmpty {
                    Text("·")
                }
                if !when.isEmpty {
                    Text(when)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(hexv: 0x8a7d75))
        }
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
// REAL: an inline text field. Enter (or the "Ajouter" button) stores the fact verbatim.
private struct MemoryAddFactRow: View {
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = ""
        Task { await state.addFact(t) }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("+")
                .font(.system(size: 15))
                .foregroundStyle(Color(hexv: 0xc79a82))
            TextField("", text: $text, prompt:
                Text("Ajouter un fait (ex. « je suis allergique aux arachides »)")
                    .foregroundColor(Color(hexv: 0xc79a82).opacity(0.85)))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Color(hexv: 0xe7d8cb))
                .focused($focused)
                .onSubmit(submit)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: submit) {
                    Text("Ajouter")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hexv: 0xe8b48f))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((hovering || focused) ? Color(hexv: 0xff783c).opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color(hexv: 0xff965a).opacity(focused ? 0.45 : 0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onHover { hovering = $0 }
    }
}

// MARK: - Wiki column

private struct MemoryWikiColumn: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Ce qu'Ember sait de toi · profil auto-maintenu")
                .padding(.bottom, 13)
            MemoryProfilePanel()
            SectionLabel("Appris récemment")
                .padding(.top, 24)
                .padding(.bottom, 13)
            MemoryRecent()
        }
    }
}

// REAL personal profile — synthesized locally from your facts, refreshed while Ember is idle.
private struct MemoryProfilePanel: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TagPill(text: "\(state.facts.count) fait\(state.facts.count > 1 ? "s" : "")",
                        fg: Color(hexv: 0xe8b48f), bg: Color(hexv: 0xff965a).opacity(0.14), radius: 8, fontSize: 11)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)
            if state.profileText.isEmpty {
                Text("Ton profil se construit tout seul au fil de vos échanges — et quand Ember est en veille. Parle-lui un peu, puis reviens ici.")
                    .font(.emberSerif(15.5, weight: .regular)).foregroundStyle(Color(hexv: 0xcdbcb0))
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.profileText)
                    .font(.emberSerif(16, weight: .regular)).foregroundStyle(Color(hexv: 0xe7d3c5))
                    .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.top, 14)
            Text("Synthétisé en local à partir de tes faits · mis à jour quand Ember est en veille")
                .font(.system(size: 11.5)).foregroundStyle(Color(hexv: 0x8a7d75))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 13)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }
}

// REAL recent facts (no fictional timeline).
private struct MemoryRecent: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.facts.isEmpty {
                Text("Rien encore — apprends-lui quelque chose (ou parle-lui) et ça apparaîtra ici.")
                    .font(.system(size: 12.5)).foregroundStyle(Color(hexv: 0x8a7d75)).padding(.vertical, 4)
            } else {
                let recent = Array(state.facts.suffix(6).reversed())
                ForEach(Array(recent.enumerated()), id: \.element.id) { idx, f in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 0) {
                            Circle().fill(Color(hexv: 0xff9a4a)).frame(width: 9, height: 9)
                                .shadow(color: Color(hexv: 0xff9a4a), radius: 4).padding(.top, 5)
                            if idx != recent.count - 1 {
                                Rectangle().fill(Color(hexv: 0xffaa78).opacity(0.2)).frame(width: 1.5)
                                    .frame(minHeight: 14, maxHeight: .infinity)
                            }
                        }
                        .frame(width: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.text).font(.system(size: 13.5)).foregroundStyle(Color(hexv: 0xe7d8cb))
                                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                            let when = factRelativeDate(f.createdAt)
                            if !when.isEmpty {
                                Text(when).font(.system(size: 11)).foregroundStyle(Color(hexv: 0x8a7d75))
                            }
                        }
                        .padding(.bottom, 14)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
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
