import SwiftUI

@main
struct ANEForgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 820, minHeight: 560)
                .task { await state.refresh() }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
