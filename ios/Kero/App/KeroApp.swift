import SwiftUI

@main
struct KeroApp: App {
    @State private var model = AppModel(store: HostStore())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // The app's phase, of all its scenes: hosts connect while it is
            // in front and let go as it goes to the background.
            switch phase {
            case .active: model.activate()
            case .background: model.deactivate()
            default: break
            }
        }
        .commands {
            CommandMenu("Session") {
                Button("Quick Jump") { model.jumpToAttention() }
                    .keyboardShortcut("j", modifiers: .command)
                Button("New Session") { model.newSession() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Pane") { model.splitFocused(direction: "right") }
                    .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}
