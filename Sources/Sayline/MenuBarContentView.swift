import SwiftUI

struct MenuBarContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sayline")
                .font(.headline)
            Text("V0 — scaffold only, no dictation yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
