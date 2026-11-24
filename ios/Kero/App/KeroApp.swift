import SwiftUI

@main
struct KeroApp: App {
    @State private var model = AppModel(store: HostStore())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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
