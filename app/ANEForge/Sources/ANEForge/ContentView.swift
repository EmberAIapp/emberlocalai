import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showingCreate = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if state.selected != nil {
                ModelView()
            } else {
                WelcomeView(showingCreate: $showingCreate)
            }
        }
        .sheet(isPresented: $showingCreate) { CreateSheet() }
        .alert("Erreur", isPresented: .constant(state.errorText != nil)) {
            Button("OK") { state.errorText = nil }
        } message: { Text(state.errorText ?? "") }
    }

    private var sidebar: some View {
        List(selection: $state.selected) {
            Section("Mes IA") {
                ForEach(state.models) { m in
                    Label(m.name, systemImage: "brain")
                        .badge("v\(m.version)")
                        .tag(m)
                }
            }
        }
        .navigationTitle("ANEForge")
        .toolbar {
            ToolbarItem {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
                    .help("Créer une nouvelle IA")
            }
        }
        .frame(minWidth: 220)
    }
}

/// First-run / no-selection welcome — one clear action.
struct WelcomeView: View {
    @Binding var showingCreate: Bool
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("Votre IA personnelle, sur votre Mac")
                .font(.largeTitle.bold())
            Text("Elle apprend de vos données. Rien ne quitte votre machine.")
                .foregroundStyle(.secondary)
            Button { showingCreate = true } label: {
                Label("Créer mon IA", systemImage: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
    }
}

struct CreateSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var base = "smollm2-135m"

    private let bases = [
        ("smollm2-135m", "Léger et rapide"),
        ("smollm2-360m", "Équilibré"),
        ("qwen2.5-0.5b", "Plus malin (multilingue)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Créer mon IA").font(.title2.bold())
            TextField("Nom (ex: mon-assistant)", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Modèle de base", selection: $base) {
                ForEach(bases, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Créer") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    Task { await state.create(name: n, base: base); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
