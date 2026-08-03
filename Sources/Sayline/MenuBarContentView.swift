import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sayline")
                .font(.headline)

            if appDelegate.isAccessibilityTrusted {
                Text(appDelegate.isRecording ? "Listening…" : "Hold Right ⌥ to talk")
                    .font(.caption)
                    .foregroundStyle(appDelegate.isRecording ? .red : .secondary)
            } else {
                Text("Accessibility permission needed")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Grant Accessibility Access") {
                    appDelegate.requestAccessibilityPermission()
                }
                Button("I've granted it — recheck") {
                    appDelegate.refreshAccessibilityStatus()
                }
            }

            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
