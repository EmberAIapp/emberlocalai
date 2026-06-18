import SwiftUI

@main
struct ANEForgeApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 820, minHeight: 720)   // bar adapte (compacte) sous ~838px
                .task { await state.boot() }
                // Sauve l'historique IMMÉDIATEMENT quand l'app perd le focus / se ferme → les derniers
                // tours ne sont jamais perdus sur un Cmd-Q juste après une réponse.
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { state.flushHistory() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)   // the design canvas — keeps the layout from cramping
    }
}
