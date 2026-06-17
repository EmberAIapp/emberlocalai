import SwiftUI

@main
struct ANEForgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 720)
                .task { await state.boot() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)   // the design canvas — keeps the layout from cramping
    }
}
