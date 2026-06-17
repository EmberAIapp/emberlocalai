import SwiftUI

// Static, illustrative content lifted 1:1 from the Ember.dc design.
// The chat, memory, settings (persona / length) and ingestion flows are wired to the
// real local engine; the connectors, wiki, timeline, agent-fil steps and Mode-Her
// orchestration shown here illustrate the product's roadmap surfaces (cahier des charges).

// MARK: - Apprendre / ingestion

struct Connector: Identifiable {
    let id = UUID()
    let name: String
    let desc: String
    let icon: String
    let iconBg: Color
    var connected: Bool
}

struct LearnedSource: Identifiable {
    let id = UUID()
    let name: String
    let meta: String
    let icon: String
    let iconBg: Color
    let status: String      // "Appris" / "En cours" / "En attente"
    let ok: Bool
}

enum DesignData {
    static let connectors: [Connector] = [
        .init(name: "Apple Notes", desc: "38 notes lisibles", icon: "🗒️",
              iconBg: Color(hexv: 0xffd250).opacity(0.16), connected: true),
        .init(name: "Mail", desc: "Boîte locale", icon: "✉️",
              iconBg: Color(hexv: 0x78aaff).opacity(0.16), connected: false),
        .init(name: "Obsidian", desc: "Coffre Markdown", icon: "🔮",
              iconBg: Color(hexv: 0xb482ff).opacity(0.16), connected: true),
    ]

    static func sources(ingesting: Bool) -> [LearnedSource] {
        [
            .init(name: "projet-cafe.md", meta: "Markdown · 4 ko · indexé", icon: "📄",
                  iconBg: Color(hexv: 0xff965a).opacity(0.14), status: "Appris", ok: true),
            .init(name: "Notes — Croix-Rousse", meta: "3 notes · Apple Notes", icon: "🗒️",
                  iconBg: Color(hexv: 0xffd250).opacity(0.14), status: "Appris", ok: true),
            .init(name: "Dossier /Recettes", meta: "12 fichiers · Obsidian", icon: "📁",
                  iconBg: Color(hexv: 0xb482ff).opacity(0.14),
                  status: ingesting ? "En cours" : "Appris", ok: !ingesting),
            .init(name: "bail-belfort.pdf", meta: "PDF · 1.2 Mo", icon: "📕",
                  iconBg: Color(hexv: 0x78aaff).opacity(0.14), status: "En attente", ok: false),
        ]
    }

    // MARK: - Mémoire (illustrative facts mirror the design; real facts come from the engine)

    static let timeline: [(text: String, when: String, dot: Color, last: Bool)] = [
        ("A précisé le budget : ~85 k€", "Aujourd'hui · 14:20", Color(hexv: 0xff8a48), false),
        ("Local rue de Belfort avec cave voûtée préféré", "Hier · 19:05", Color(hexv: 0xe0a079), false),
        ("Création de la mémoire « Mon Ember »", "Il y a 3 jours", Color(hexv: 0x7c6f67), true),
    ]

    // MARK: - Réglages

    struct ModelChoice: Identifiable {
        let id = UUID()
        let name: String
        let desc: String
        let ram: String
        let speed: String
        var modelId: String = ""      // REAL MLX model id — switching actually reloads this model
    }

    static let modelCatalog: [ModelChoice] = [
        .init(name: "Léger", desc: "Qwen2.5 0.5B — rapide, petites configs.", ram: "8 Go", speed: "rapide",
              modelId: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
        .init(name: "Équilibré", desc: "Qwen2.5 1.5B — fluide & multilingue. Recommandé.", ram: "16 Go", speed: "56 tok/s",
              modelId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit"),
        .init(name: "Puissant", desc: "Qwen2.5 3B — réponses plus riches.", ram: "24 Go+", speed: "34 tok/s",
              modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit"),
    ]

    static let personaOptions = ["Calme", "Vif", "Professionnel", "Chaleureux"]

    struct Permission: Identifiable {
        let id = UUID()
        let key: String
        let icon: String
        let desc: String
    }

    static let permissions: [Permission] = [
        .init(key: "Fichiers", icon: "📂", desc: "Lire et organiser tes fichiers"),
        .init(key: "Apps", icon: "🪟", desc: "Ouvrir et piloter des apps"),
        .init(key: "Recherche", icon: "🔎", desc: "Recherche web (désactivé = 100% local)"),
        .init(key: "Calendrier", icon: "📅", desc: "Lire et créer des événements"),
        .init(key: "Automatisations", icon: "⚡", desc: "Enchaîner plusieurs actions"),
    ]

    static let defaultPermissions: [String: Bool] = [
        "Fichiers": true, "Apps": true, "Recherche": false, "Calendrier": true, "Automatisations": false,
    ]

    // MARK: - Le fil / Mode Her — agent orchestration steps

    struct AgentStep: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let text: String
        var gate: Bool = false
    }

    static let agentSteps: [AgentStep] = [
        .init(icon: "🔎", title: "Recherche", text: "Compare des cafés-librairies à Lyon"),
        .init(icon: "📂", title: "Fichiers", text: "Compile un dossier projet sur ton Mac"),
        .init(icon: "📅", title: "Calendrier", text: "Bloquer la visite du local — jeudi 10 h", gate: true),
        .init(icon: "🧠", title: "Mémoire", text: "Vérifie le budget dans ta mémoire"),
        .init(icon: "✉️", title: "Mail", text: "Prépare un brouillon au propriétaire"),
    ]

    static let herTranscript = "« Prépare-moi le dossier pour la visite du local, et bloque jeudi 10 h. »"

    static let homeSuggestions = [
        "Carte des boissons du café",
        "Palette couleur pour l'identité",
        "Budget d'ouverture en graphique",
        "Rétroplanning d'ouverture",
    ]
}
