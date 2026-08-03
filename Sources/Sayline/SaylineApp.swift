import SwiftUI

@main
struct SaylineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appDelegate)
        } label: {
            Image(systemName: appDelegate.isRecording ? "mic.fill" : "mic")
        }
    }
}
