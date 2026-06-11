import SwiftUI
import UniformTypeIdentifiers

/// The per-model screen: teach it (drop data) on top, chat below.
struct ModelView: View {
    @EnvironmentObject var state: AppState
    @State private var draftPrompt = ""
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            teachBar
            Divider()
            chat
            inputBar
        }
        .navigationTitle(state.selected?.name ?? "")
    }

    // MARK: Teach (drag-and-drop a data file)

    private var teachBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("Apprendre de vos données").font(.headline)
                Text(state.isBusy
                     ? (state.trainingLog.last ?? "Apprentissage…")
                     : "Glissez un fichier .txt ici, ou cliquez pour choisir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.isBusy { ProgressView().controlSize(.small) }
            Button("Choisir…") { pickFile() }.disabled(state.isBusy)
        }
        .padding(12)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers); return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let p = providers.first else { return }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { Task { await state.teach(dataPath: url.path) } }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.teach(dataPath: url.path) }
        }
    }

    // MARK: Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(state.messages) { msg in
                        Bubble(message: msg).id(msg.id)
                    }
                }
                .padding()
            }
            .onChange(of: state.messages.count) {
                if let last = state.messages.last { proxy.scrollTo(last.id) }
            }
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Écrivez à votre IA…", text: $draftPrompt, onCommit: sendDraft)
                .textFieldStyle(.roundedBorder)
            Button(action: sendDraft) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .disabled(state.isBusy || draftPrompt.isEmpty)
        }
        .padding(12)
    }

    private func sendDraft() {
        let p = draftPrompt.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        draftPrompt = ""
        Task { await state.send(p) }
    }
}

struct Bubble: View {
    let message: ChatMessage
    var body: some View {
        HStack {
            if message.role == .user { Spacer() }
            Text(message.text)
                .padding(10)
                .background(message.role == .user ? Color.accentColor : Color.gray.opacity(0.2))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 460, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer() }
        }
    }
}
