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
    private static func dir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ember/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Clé de fichier SANS perte (anti-collision) : le slug écrasait casse/accents/ponctuation et
    /// tronquait à 48 → deux IA distinctes pouvaient partager le même fichier (perte de données).
    /// On encode le nom brut (filesystem-safe) : noms distincts → fichiers distincts, garanti.
    nonisolated static func key(_ name: String) -> String {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return enc.isEmpty ? "ia" : enc
    }

    nonisolated static func fileURL(_ name: String) -> URL { dir().appendingPathComponent("\(key(name)).json") }

    /// Écriture SYNCHRONE (fermeture de l'app / changement d'IA) — pour ne rien perdre.
    nonisolated static func saveSync(_ name: String, _ items: [TimelineItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL(name), options: .atomic)
    }

    /// Migration douce de l'ancien fichier slug.json (lossy) vers la clé stable, une seule fois.
    private func migrateIfNeeded(_ name: String) {
        let fm = FileManager.default
        let new = Self.fileURL(name)
        guard !fm.fileExists(atPath: new.path) else { return }
        let old = Self.dir().appendingPathComponent("\(AppState.slug(name)).json")
        if fm.fileExists(atPath: old.path), old.path != new.path {
            try? fm.moveItem(at: old, to: new)
        }
    }

    func load(_ name: String) -> [TimelineItem] {
        migrateIfNeeded(name)
        guard let data = try? Data(contentsOf: Self.fileURL(name)) else { return [] }
        return (try? JSONDecoder().decode([TimelineItem].self, from: data)) ?? []
    }

    func save(_ name: String, _ items: [TimelineItem]) { Self.saveSync(name, items) }

    /// CRUD fichier — renommer une IA déplace son historique (sinon il est orphelin → perdu).
    func rename(from old: String, to new: String) {
        let fm = FileManager.default
        let src = Self.fileURL(old), dst = Self.fileURL(new)
        guard src.path != dst.path, fm.fileExists(atPath: src.path) else { return }
        try? fm.removeItem(at: dst)            // au cas où une cible vide existe
        try? fm.moveItem(at: src, to: dst)
    }

    /// CRUD fichier — supprimer une IA supprime son historique (sinon il reste orphelin).
    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: Self.fileURL(name))
    }
}
