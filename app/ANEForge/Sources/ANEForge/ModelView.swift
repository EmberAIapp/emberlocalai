import SwiftUI
import UniformTypeIdentifiers

/// Per-model screen: teach it (drop data) on top, chat below — all in the Ember theme.
struct ModelView: View {
    @EnvironmentObject var state: AppState
    @State private var draftPrompt = ""
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            teachBar
            Divider().overlay(Color.ember2.opacity(0.15))
            chat
            inputBar
        }
        .background(Color.emberBg)
        .navigationTitle(state.selected?.name ?? "")
    }

    // MARK: Teach (drag-and-drop a data file)

    private var teachBar: some View {
        HStack(spacing: 14) {
            EmberOrb(size: 22, active: state.isBusy).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.isBusy ? "Ember apprend…" : "Apprendre de vos données")
                    .font(.headline).foregroundStyle(.emberInk)
                Text(state.isBusy
                     ? (state.trainingLog.last ?? "…")
                     : "Glissez un fichier .txt ici, ou choisissez-en un.")
                    .font(.caption).foregroundStyle(.emberMuted).lineLimit(1)
            }
            Spacer()
            Button("Choisir…") { pickFile() }
                .buttonStyle(.plain)
                .foregroundStyle(.ember1)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Color.ember2.opacity(0.10)).clipShape(Capsule())
                .overlay(Capsule().stroke(Color.ember2.opacity(0.3)))
                .disabled(state.isBusy)
        }
        .padding(14)
        .background(isTargeted ? Color.ember2.opacity(0.12) : Color.emberBg2.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(isTargeted ? Color.ember2 : .clear, lineWidth: 1))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers); return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let p = providers.first else { return }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in await state.teachFile(url) }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.teachFile(url) }
        }
    }

    // MARK: Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if state.messages.isEmpty {
                        VStack(spacing: 14) {
                            EmberOrb(size: 54).frame(height: 130)
                            Text("Demandez-lui quelque chose.")
                                .foregroundStyle(.emberMuted)
                        }.padding(.top, 60)
                    }
                    ForEach(state.messages) { msg in
                        Bubble(message: msg).id(msg.id)
                    }
                }
                .padding()
            }
            .onChange(of: state.messages.count) {
                if let last = state.messages.last { withAnimation { proxy.scrollTo(last.id) } }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Écrivez à votre IA…", text: $draftPrompt)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.emberBg2).clipShape(Capsule())
                .overlay(Capsule().stroke(Color.ember2.opacity(0.25)))
                .foregroundStyle(.emberInk)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill").font(.title)
                    .foregroundStyle(draftPrompt.isEmpty ? Color.emberFaint : Color.ember2)
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy || draftPrompt.isEmpty)
        }
        .padding(14)
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
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    message.role == .user
                    ? AnyShapeStyle(LinearGradient(colors: [.ember1, .ember2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.emberBg2))
                .foregroundStyle(message.role == .user ? Color(hexv: 0x1a0d05) : .emberInk)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if message.role == .assistant {
                        RoundedRectangle(cornerRadius: 16).stroke(Color.ember2.opacity(0.15))
                    }
                }
                .frame(maxWidth: 460, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer() }
        }
    }
}
