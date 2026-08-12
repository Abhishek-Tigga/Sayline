import SwiftUI

@main
struct SaylineApp: App {
    init() {
        // Before anything becomes an app. `--dump-config` and
        // `--parse-actions` let the eval ask the real binary instead of
        // rebuilding it from a hand-maintained file list, which broke three
        // times. Returns immediately when no mode was asked for.
        HeadlessModes.runIfRequested()
    }

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
