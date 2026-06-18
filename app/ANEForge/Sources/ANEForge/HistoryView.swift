import SwiftUI

/// La timeline relisible (Étape 2) — les 3 lentilles sur la même source : Conversation / Travail /
/// Créations. Chronologique, filtrable ; chaque entrée ramène à son étape (ou ouvre le fichier).
/// 100% local : tout est lu depuis l'historique sur le Mac.
struct HistoryView: View {
    @EnvironmentObject var state: AppState

    enum Lens: String, CaseIterable, Identifiable {
        case tout = "All", conversation = "Conversation", travail = "Work", creations = "Creations"
        var id: String { rawValue }
    }
    @State private var lens: Lens = .tout
    @State private var query = ""
    @State private var showingClear = false

    private var items: [TimelineItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return state.history.filter { item in
            let lensOK: Bool
            switch lens {
            case .tout:         lensOK = true
            case .conversation: lensOK = item.kind == .you || item.kind == .ember
            case .travail:      lensOK = item.kind == .task
            case .creations:    lensOK = item.kind == .creation
            }
            guard lensOK else { return false }
            guard !q.isEmpty else { return true }
            return item.text.lowercased().contains(q) || (item.detail?.lowercased().contains(q) ?? false)
        }.reversed()   // le plus récent d'abord
    }

    // Regroupé par jour pour le repère chronologique (Aujourd'hui / Hier / date).
    private var grouped: [(String, [TimelineItem])] {
        var order: [String] = []
        var map: [String: [TimelineItem]] = [:]
        let cal = Calendar.current
        for it in items {
            let key = dayLabel(it.date, cal)
            if map[key] == nil { map[key] = []; order.append(key) }
            map[key]?.append(it)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func dayLabel(_ date: Date, _ cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var creationCount: Int { state.history.filter { $0.kind == .creation }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // En-tête
                HStack(alignment: .center, spacing: 14) {
                    EmberOrb(mode: .ecoute, size: 34).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History & creations").font(.emberSerif(26)).foregroundStyle(.emberInk)
                        Text("Go back to every key step. \(Text("Everything stays on your Mac.").foregroundColor(Color(hexv: 0x7fd095)))")
                            .font(.system(size: 13)).foregroundStyle(.emberMuted)
                    }
                    Spacer()
                    if !state.history.isEmpty {
                        Button { showingClear = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "trash").font(.system(size: 11))
                                Text("Clear all").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(Color(hexv: 0xd88a72))
                            .padding(.vertical, 6).padding(.horizontal, 12)
                            .background(Capsule().strokeBorder(Color(hexv: 0xd85a30).opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain).help("Clear this AI's entire history")
                    }
                }

                // Filtres = les 3 lentilles (+ Tout) + recherche
                HStack(spacing: 9) {
                    ForEach(Lens.allCases) { l in
                        ChipButton(label: l.rawValue, selected: lens == l) { lens = l }
                    }
                    Spacer()
                    if creationCount > 0 {
                        Text("\(creationCount) creation\(creationCount > 1 ? "s" : "")")
                            .font(.system(size: 11)).foregroundStyle(Color(hexv: 0x8a9b8e))
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color(hexv: 0x9a8d84))
                    TextField("Search in history…", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.emberInk)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color(hexv: 0x8a7d75))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.08), lineWidth: 1))

                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: query.isEmpty ? "clock" : "magnifyingglass").font(.system(size: 26)).foregroundStyle(Color(hexv: 0x6a5b52))
                        Text(state.history.isEmpty
                             ? "Nothing yet. Talk to Ember or give her a task — everything will be archived here."
                             : (query.isEmpty ? "No items in this lens." : "No results for \"\(query)\"."))
                            .font(.system(size: 13)).foregroundStyle(.emberMuted).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(grouped, id: \.0) { day, rows in
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(LocalizedStringKey(day))
                                ForEach(rows) { row($0) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40).padding(.top, 26).padding(.bottom, 40)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .alert("Clear all?", isPresented: $showingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear all", role: .destructive) { state.clearHistory() }
        } message: {
            Text("Clears this AI's entire history (conversation, work, creations) and the thread. Files already generated stay on your Mac.")
        }
    }

    private func row(_ item: TimelineItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(item.kind)).font(.system(size: 14)).foregroundStyle(tint(item.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(label(item.kind)).font(.system(size: 10.5, weight: .medium)).tracking(0.6)
                        .foregroundStyle(tint(item.kind))
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5)).foregroundStyle(Color(hexv: 0x7c6f67))
                }
                Text(item.text).font(.system(size: 13)).foregroundStyle(Color(hexv: 0xe8d4c6))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let d = item.detail, item.kind == .task {
                    Text(d).font(.system(size: 11.5)).foregroundStyle(.emberMuted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            actions(item)
            // CRUD : supprimer cette entrée (le fichier d'une création reste sur le disque).
            Button { state.deleteHistoryItem(item.id) } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Color(hexv: 0x8a7d75))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).help("Delete this entry")
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(corner: 13)
    }

    @ViewBuilder private func actions(_ item: TimelineItem) -> some View {
        if item.kind == .creation, let p = item.path {
            HStack(spacing: 7) {
                Button { state.openPath(p) } label: { pill("Open", filled: true) }.buttonStyle(.plain)
                Button { state.revealPath(p) } label: { pill("Reveal", filled: false) }.buttonStyle(.plain)
            }
        } else {
            Button { state.jumpToHistory(item.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                    Text("Go back").font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color(hexv: 0xd8c6ba))
                .padding(.vertical, 5).padding(.horizontal, 11)
                .background(Capsule().fill(.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("Go back to this step in Her")
        }
    }

    private func pill(_ t: String, filled: Bool) -> some View {
        Text(t).font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(filled ? Color(hexv: 0x123) : Color(hexv: 0x9fd9ad))
            .padding(.vertical, 5).padding(.horizontal, 12)
            .background(
                Group {
                    if filled { Capsule().fill(Color(hexv: 0x5fd07a).opacity(0.85)) }
                    else { Capsule().strokeBorder(Color(hexv: 0x5fd07a).opacity(0.35), lineWidth: 1) }
                }
            )
    }

    private func icon(_ k: TimelineItem.Kind) -> String {
        switch k {
        case .you:      return "person.fill"
        case .ember:    return "text.bubble.fill"
        case .task:     return "checkmark.seal.fill"
        case .creation: return "doc.text.fill"
        }
    }
    private func tint(_ k: TimelineItem.Kind) -> Color {
        switch k {
        case .you:      return Color(hexv: 0x8a7a70)
        case .ember:    return Color(hexv: 0xc79a82)
        case .task:     return Color(hexv: 0xffa050)
        case .creation: return Color(hexv: 0x7fd095)
        }
    }
    private func label(_ k: TimelineItem.Kind) -> String {
        switch k {
        case .you:      return "YOU"
        case .ember:    return "EMBER"
        case .task:     return "WORK"
        case .creation: return "CREATION"
        }
    }
}
