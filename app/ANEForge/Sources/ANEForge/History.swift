import Foundation

/// One key step of the timeline — the single source the 3 « lentilles » (conversation / travail /
/// créations) read from. Persisted per-IA so the fil survive la fermeture et le changement d'IA.
struct TimelineItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case you, ember, task, creation }
    let id: UUID
    let date: Date
    let kind: Kind
    var text: String
    var detail: String?      // task : la synthèse ; creation : sous-titre
    var path: String?        // creation : chemin du fichier (pour Ouvrir/Révéler)

    init(id: UUID = UUID(), date: Date, kind: Kind, text: String, detail: String? = nil, path: String? = nil) {
        self.id = id; self.date = date; self.kind = kind; self.text = text; self.detail = detail; self.path = path
    }
}

/// Local, file-based history — 100% sur le Mac (aucun cloud). Un JSON par IA dans
/// Application Support/Ember/history/. IO hors du main thread (actor).
actor HistoryStore {
    private func fileURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ember/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(AppState.slug(name)).json")
    }

    func load(_ name: String) -> [TimelineItem] {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return [] }
        return (try? JSONDecoder().decode([TimelineItem].self, from: data)) ?? []
    }

    func save(_ name: String, _ items: [TimelineItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL(name), options: .atomic)
    }
}
