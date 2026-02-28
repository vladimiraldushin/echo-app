import SwiftUI
import SwiftData

@main
struct EchoApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: [AudioFile.self, TranscriptionResult.self, Segment.self, Speaker.self])
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Открыть файл…") {
                    NotificationCenter.default.post(name: .openFilePicker, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openFilePicker = Notification.Name("echo.openFilePicker")
}
