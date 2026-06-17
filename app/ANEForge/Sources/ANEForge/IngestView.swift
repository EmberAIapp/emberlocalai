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

                // CONNECTEURS LOCAUX · LECTURE SEULE — Apple Notes + tes propres dossiers (réels).
                SectionLabel("Connecteurs locaux · lecture seule")
                    .padding(.top, 30)
                    .padding(.bottom, 14)
                VStack(spacing: 10) {
                    AppleNotesCard()
                    ForEach(state.connectedFolders, id: \.self) { path in
                        ConnectedFolderCard(path: path)
                    }
                    ConnectFolderCard(onPick: pickFolder)
                }

                // « Apprentissage complet » — son propre bloc héro, nettement distinct des connecteurs.
                FullLearnHero(onWholeMac: { state.learnWholeMac() },
                              onPickFolders: pickFolders,
                              onSettings: openDiskAccess)
                    .padding(.top, 26)

                if state.isLearning {
                    progressPanel
                        .padding(.top, 18)
                }

                if !state.lastLearned.isEmpty {
                    learnedPanel
                        .padding(.top, 18)
                }

                learnedHint
                    .padding(.top, 18)
            }
            .padding(.top, 34)
            .padding(.horizontal, 48)
            .padding(.bottom, 40)
        }
        // Keep the fact count + connectors fresh.
        .task(id: state.selected?.name) {
            state.loadConnectedFolders()
            if let n = state.selected?.name { await state.loadFacts(n) }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Connecter"
        panel.message = "Choisis un dossier — Ember en apprendra les fichiers .txt/.md/.pdf, en local."
        if panel.runModal() == .OK, let url = panel.url {
            state.connectFolder(url)
        }
    }

    // Ouvre le volet « Accès complet au disque » des Réglages système — c'est l'UTILISATEUR
    // qui accorde (je ne touche jamais un réglage de sécurité système moi-même).
    private func openDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // « Apprentissage complet » — choisis PLUSIEURS dossiers d'un coup (Documents, Bureau, projets…).
    // 100% local, borné, annulable. Chaque dossier choisi accorde son accès (pas d'accès disque global).
    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Apprendre de tout ça"
        panel.message = "Choisis les dossiers qu'Ember peut apprendre (Documents, Bureau, tes projets…). Tout reste en local."
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            state.connectFolders(panel.urls, full: true)
        }
    }

    // « Voici ce que j'ai appris » — rend l'apprentissage tangible (les faits extraits à l'instant).
    private var learnedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Color(hexv: 0x9fd9ad))
                Text("Voici ce qu'Ember vient de retenir")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xe8c4a8))
                Spacer(minLength: 0)
            }
            ForEach(state.lastLearned.prefix(8)) { f in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Color(hexv: 0x9fd9ad))
                    Text(f.text).font(.system(size: 12.5)).foregroundStyle(Color(hexv: 0xe7d8cb))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if state.lastLearned.count > 8 {
                Text("… et \(state.lastLearned.count - 8) autre(s) — tout est dans Mémoire.")
                    .font(.system(size: 11.5)).foregroundStyle(Color(hexv: 0x8a7d75))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hexv: 0x5fd07a).opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(hexv: 0x5fd07a).opacity(0.20), lineWidth: 1))
    }

    // Honest pointer: learned facts live in Mémoire (no fake "sources" list).
    private var learnedHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(Color(hexv: 0x9fd9ad))
            Text(state.facts.isEmpty
                 ? "Ce qu'Ember apprend de tes données apparaît dans l'onglet Mémoire."
                 : "Ember connaît \(state.facts.count) fait\(state.facts.count > 1 ? "s" : "") sur toi — vois l'onglet Mémoire.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hexv: 0x8a7d75))
            Spacer(minLength: 0)
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
                Spacer(minLength: 8)
                Button { state.cancelLearning() } label: {
                    Text("Arrêter")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(hexv: 0xff8a7a))
                        .padding(.vertical, 4).padding(.horizontal, 11)
                        .overlay(Capsule().stroke(Color(hexv: 0xff5a46).opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
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

    private func openPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true       // plusieurs fichiers
        panel.canChooseDirectories = true          // … ou des dossiers (tenu : « ou dossiers »)
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, .text, .data, .folder]
        panel.prompt = "Apprendre"
        if panel.runModal() == .OK {
            state.learn(panel.urls)
        }
    }

    // A dropped file OR folder (teachPaths walks folders). Multi-file → use "clique pour parcourir".
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in state.learn([url]) }
        }
        return true
    }
}

// MARK: - Apple Notes connector (REAL — reads your notes and learns facts, §4.A)
// CRUD : Apprendre/Re-synchroniser (create/update) + 🗑 oublier ce qu'il a appris (delete).
// Pas de ✕ : Apple Notes est une source intégrée, on ne la « retire » pas — on oublie ses faits.
private struct AppleNotesCard: View {
    @EnvironmentObject var state: AppState
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(hexv: 0xffd250).opacity(0.16))
                Text("🗒️").font(.system(size: 19))
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Notes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xecd9c9))
                Text("Lis tes notes et apprends-en des faits — 100% en local")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
            }
            Spacer()
            // Create / Update : (ré)apprendre les notes
            Button { Task { await state.teachNotes() } } label: {
                TagPill(
                    text: state.isLearning ? "Lecture…" : "Apprendre mes notes",
                    fg: Color(hexv: 0x9fd9ad),
                    bg: Color(hexv: 0x5fd07a).opacity(0.12)
                )
            }
            .buttonStyle(.plain).disabled(state.isLearning)
            .help("(Ré)apprendre tes notes Apple")
            // Delete : oublier ce que les notes ont appris
            Button { Task { await state.forgetNotes() } } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hexv: 0xff8a7a))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).disabled(state.isLearning)
            .help("Oublier ce qu'Ember a appris de tes notes")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.06 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(hexv: 0x5fd07a).opacity(hover ? 0.30 : 0.12), lineWidth: 1)
        )
        .onHover { hover = $0 }
    }
}

// MARK: - A connected folder (chosen by the user — persisted, re-syncable, removable)
private struct ConnectedFolderCard: View {
    @EnvironmentObject var state: AppState
    let path: String
    @State private var hover = false

    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(hexv: 0xff965a).opacity(0.16))
                Text("📁").font(.system(size: 19))
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xecd9c9))
                Text(path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            // Update : re-apprendre
            Button { state.resyncFolder(path) } label: {
                TagPill(text: state.isLearning ? "…" : "Re-synchroniser",
                        fg: Color(hexv: 0x9fd9ad), bg: Color(hexv: 0x5fd07a).opacity(0.12))
            }
            .buttonStyle(.plain).disabled(state.isLearning)
            .help("Re-apprendre ce dossier")
            // Delete-data : oublier ce qu'il a appris (+ retire le connecteur)
            Button { Task { await state.forgetConnector(path) } } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hexv: 0xff8a7a))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).disabled(state.isLearning)
            .help("Oublier ce que ce dossier a appris, et le retirer")
            // Delete-connector only : retire le connecteur, garde les faits
            Button { state.disconnectFolder(path) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0x8a7d75))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Retirer le connecteur (garder les faits appris)")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - "Connecter un dossier" (choisis n'importe quel dossier du Mac)
private struct ConnectFolderCard: View {
    @EnvironmentObject var state: AppState
    var onPick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hexv: 0xc79a82))
                Text("Connecter un dossier — choisis ce qu'Ember peut lire (Obsidian, Documents, un projet…)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hexv: 0xc79a82))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hover ? Color(hexv: 0xff783c).opacity(0.06) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(hexv: 0xff965a).opacity(0.25),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(.plain)
        .disabled(state.isLearning)
        .onHover { hover = $0 }
    }
}

// MARK: - « Apprentissage complet » — bloc héro (un MODE, pas un connecteur de plus)
private struct FullLearnHero: View {
    @EnvironmentObject var state: AppState
    var onWholeMac: () -> Void
    var onPickFolders: () -> Void
    var onSettings: () -> Void
    @State private var hover = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // En-tête : icône braise rayonnante + titre éditorial + badge MODE
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color(hexv: 0xffcf9a), Color(hexv: 0xff6a26), Color(hexv: 0xc42a12)],
                            center: UnitPoint(x: 0.35, y: 0.30), startRadius: 1, endRadius: 26))
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                .shadow(color: Color(hexv: 0xff6e32).opacity(pulse ? 0.75 : 0.45), radius: pulse ? 16 : 9)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Apprentissage complet")
                            .font(.emberSerif(21))
                            .foregroundStyle(Color(hexv: 0xf5e7db))
                        Text("MODE")
                            .font(.system(size: 9, weight: .bold)).tracking(1)
                            .foregroundStyle(Color(hexv: 0xffd9b8))
                            .padding(.vertical, 2).padding(.horizontal, 6)
                            .background(Capsule().fill(Color(hexv: 0xff783c).opacity(0.22)))
                    }
                    Text("Ouvre Ember sur ton Mac")
                        .font(.system(size: 12.5)).foregroundStyle(Color(hexv: 0xc79a82))
                }
                Spacer(minLength: 0)
            }

            Text("Apprends de tout ton Mac, **100% en local** — ou choisis des dossiers précis. Système, bibliothèques et caches sont exclus. Rien ne sort, tu peux arrêter quand tu veux ; tout est inspectable dans Mémoire.")
                .font(.system(size: 13.5)).foregroundStyle(Color(hexv: 0xcdbcb0))
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            // Deux actions : tout le Mac (puissant) ou des dossiers choisis (ciblé).
            HStack(spacing: 10) {
                Button(action: onWholeMac) {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill.badge.person.crop").font(.system(size: 13, weight: .semibold))
                        Text("Tout mon Mac").font(.system(size: 13.5, weight: .bold))
                    }
                    .foregroundStyle(Color(hexv: 0x1a0f0a))
                    .padding(.vertical, 10).padding(.horizontal, 18)
                    .background(Capsule().fill(LinearGradient(
                        colors: [Color(hexv: 0xffb877), Color(hexv: 0xff6024)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: Color(hexv: 0xff5a28).opacity(0.55), radius: 12, y: 5)
                }
                .buttonStyle(.plain).disabled(state.isLearning)

                Button(action: onPickFolders) {
                    Text("Choisir des dossiers")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hexv: 0xffd9b8))
                        .padding(.vertical, 10).padding(.horizontal, 16)
                        .overlay(Capsule().stroke(Color(hexv: 0xff965a).opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain).disabled(state.isLearning)
                Spacer(minLength: 0)
            }
            .padding(.top, 16)

            // Accès complet au disque — accordé par l'UTILISATEUR (jamais par l'app).
            Button(action: onSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open").font(.system(size: 10))
                    Text("Donner l'accès complet au disque (Réglages système)")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color(hexv: 0x9bb0c4))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hexv: 0xff783c).opacity(hover ? 0.16 : 0.11),
                             Color(hexv: 0xff5a28).opacity(0.03)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(hexv: 0xff965a).opacity(hover ? 0.45 : 0.28), lineWidth: 1)
        )
        .shadow(color: Color(hexv: 0xff5a28).opacity(0.18), radius: 22, y: 10)
        .onHover { hover = $0 }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { pulse = true }
        }
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

