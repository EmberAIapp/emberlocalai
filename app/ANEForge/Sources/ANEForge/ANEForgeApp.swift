import SwiftUI

@main
struct ANEForgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 820, minHeight: 720)   // bar adapte (compacte) sous ~838px
                .task { await state.boot() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)   // the design canvas — keeps the layout from cramping
    }
}
