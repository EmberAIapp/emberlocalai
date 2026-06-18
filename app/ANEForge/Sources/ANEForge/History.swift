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
    /// Journal append-only (NDJSON) — chaque tour y est écrit DURABLEMENT tout de suite, avant la
    /// sauvegarde complète (coalescée). Un crash dur ne perd donc plus le dernier tour.
    nonisolated static func journalURL(_ name: String) -> URL { dir().appendingPathComponent("\(key(name)).log") }

    /// Écrit la base SEULE (sans toucher au journal) — utilisé par la sauvegarde coalescée.
    nonisolated static func saveBaseSync(_ name: String, _ items: [TimelineItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL(name), options: .atomic)
    }

    /// COMPACTE : écrit la base ET vide le journal (fermeture / chargement / suppression). Synchrone = sûr.
    nonisolated static func saveSync(_ name: String, _ items: [TimelineItem]) {
        saveBaseSync(name, items)
        try? FileManager.default.removeItem(at: journalURL(name))
    }

    /// Append durable d'UNE entrée (synchrone, O(1)) — la garantie crash-safe.
    nonisolated static func appendJournalSync(_ name: String, _ item: TimelineItem) {
        guard var data = try? JSONEncoder().encode(item) else { return }
        data.append(0x0A)   // '\n'
        let url = journalURL(name)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)   // crée le fichier si absent
        }
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
        var items: [TimelineItem] = []
        if let data = try? Data(contentsOf: Self.fileURL(name)) {
            items = (try? JSONDecoder().decode([TimelineItem].self, from: data)) ?? []
        }
        // Rejoue le journal : les tours appendés depuis la dernière compaction (= récupérés après
        // un crash dur), dédupliqués par id, puis on compacte (base = tout, journal vidé).
        if let jdata = try? Data(contentsOf: Self.journalURL(name)), !jdata.isEmpty {
            var seen = Set(items.map { $0.id })
            for line in jdata.split(separator: 0x0A) where !line.isEmpty {
                if let it = try? JSONDecoder().decode(TimelineItem.self, from: Data(line)), !seen.contains(it.id) {
                    items.append(it); seen.insert(it.id)
                }
            }
            Self.saveSync(name, items)
        }
        return items
    }

    func save(_ name: String, _ items: [TimelineItem]) { Self.saveBaseSync(name, items) }   // coalescé → base seule

    /// CRUD fichier — renommer une IA déplace son historique (base + journal) (sinon orphelin → perdu).
    func rename(from old: String, to new: String) {
        let fm = FileManager.default
        for (src, dst) in [(Self.fileURL(old), Self.fileURL(new)), (Self.journalURL(old), Self.journalURL(new))] {
            guard src.path != dst.path, fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)            // au cas où une cible vide existe
            try? fm.moveItem(at: src, to: dst)
        }
    }

    /// CRUD fichier — supprimer une IA supprime son historique (base + journal).
    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: Self.fileURL(name))
        try? FileManager.default.removeItem(at: Self.journalURL(name))
    }
}
