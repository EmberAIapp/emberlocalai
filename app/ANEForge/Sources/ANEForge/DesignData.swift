import SwiftUI

// Configuration data for the REAL screens: the model catalog, persona options and
// permission list feed Settings/Onboarding; the home suggestions feed Accueil.
// (Demo/fictional content — fake connectors, fake "learned sources", café timeline,
// agent-fil steps — has been removed; every screen now shows real engine data.)

enum DesignData {

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

    // Keys MATCH the agent's real SENSITIVE scopes (agent.py) → un toggle OFF bloque vraiment
    // le périmètre côté agent (granulaire + révocable, §4.E/§7).
    static let permissions: [Permission] = [
        .init(key: "Fichiers", icon: "📂", desc: "Lire et organiser tes fichiers"),
        .init(key: "Apps", icon: "🪟", desc: "Ouvrir et piloter des apps"),
        .init(key: "Notes", icon: "🗒️", desc: "Lire et créer des notes"),
        .init(key: "Rappels", icon: "✅", desc: "Lire et créer des rappels"),
        .init(key: "Agenda", icon: "📅", desc: "Lire et créer des événements"),
        .init(key: "Mémoire", icon: "🧠", desc: "Lire ta mémoire personnelle"),
        .init(key: "Mail", icon: "✉️", desc: "Préparer des brouillons (jamais envoyer)"),
        .init(key: "Raccourcis", icon: "⚡", desc: "Lancer des raccourcis Apple"),
    ]

    static let defaultPermissions: [String: Bool] = [
        "Fichiers": true, "Apps": true, "Notes": true, "Rappels": true,
        "Agenda": true, "Mémoire": true, "Mail": true, "Raccourcis": false,
    ]

    // Real, neutral starting points (no fictional café scenario) — work for anyone.
    static let homeSuggestions = [
        "Qu'est-ce que tu sais de moi ?",
        "Présente-toi en une phrase",
        "Aide-moi à organiser ma journée",
        "Apprends quelque chose sur moi",
    ]
}
