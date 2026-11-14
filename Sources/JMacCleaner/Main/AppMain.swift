import SwiftUI

@main
struct JMacCleanerApp: App {
    @State private var model = ProcessMonitorModel()

    var body: some Scene {
        WindowGroup("JMacCleaner") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Processes") {
                Button("Refresh Now") {
                    Task { await model.refreshOnce() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(model.isPaused ? "Resume Auto-Refresh" : "Pause Auto-Refresh") {
                    model.togglePause()
                }
                .keyboardShortcut("e", modifiers: .command)

                Divider()

                Button("Kill All Junk…") {
                    model.showKillAllSheet = true
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}
