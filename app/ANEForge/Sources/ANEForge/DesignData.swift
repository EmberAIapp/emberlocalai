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

    // Only the model that ACTUALLY ships embedded (offline) — advertising 0.5B/3B was hollow:
    // they aren't bundled and the offline daemon refuses to download, so picking them did nothing.
    // One honest card keeps the "100% local model" reassurance without a fake, broken choice.
    static let modelCatalog: [ModelChoice] = [
        .init(name: "Qwen2.5 1.5B", desc: "Smooth & multilingual · runs 100% on your Mac.",
              ram: "16 GB", speed: "56 tok/s",
              modelId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit"),
    ]

    static let personaOptions = ["Calm", "Lively", "Professional", "Warm"]

    struct Permission: Identifiable {
        let id = UUID()
        let key: String          // internal scope id — MUST match agent.py sensitive scopes
        let label: String        // English display title
        let icon: String
        let desc: String
    }

    // Keys MATCH the agent's real SENSITIVE scopes (agent.py) → un toggle OFF bloque vraiment
    // le périmètre côté agent (granulaire + révocable, §4.E/§7). `label` = displayed title.
    static let permissions: [Permission] = [
        .init(key: "Fichiers",   label: "Files",     icon: "📂", desc: "Read and organize your files"),
        .init(key: "Apps",       label: "Apps",      icon: "🪟", desc: "Open and control apps"),
        .init(key: "Notes",      label: "Notes",     icon: "🗒️", desc: "Read and create notes"),
        .init(key: "Rappels",    label: "Reminders", icon: "✅", desc: "Read and create reminders"),
        .init(key: "Agenda",     label: "Calendar",  icon: "📅", desc: "Read and create events"),
        .init(key: "Mémoire",    label: "Memory",    icon: "🧠", desc: "Read your personal memory"),
        .init(key: "Mail",       label: "Mail",      icon: "✉️", desc: "Prepare drafts (never send)"),
        .init(key: "Raccourcis", label: "Shortcuts", icon: "⚡", desc: "Run Apple Shortcuts"),
    ]

    static let defaultPermissions: [String: Bool] = [
        "Fichiers": true, "Apps": true, "Notes": true, "Rappels": true,
        "Agenda": true, "Mémoire": true, "Mail": true, "Raccourcis": false,
    ]
}
