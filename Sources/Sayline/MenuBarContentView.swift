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

            if !appDelegate.isMicAuthorized {
                Text("Microphone permission needed")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if appDelegate.useLocalTranscription {
                Text(appDelegate.isLocalModelDownloading
                     ? "On-device: downloading model…"
                     : (appDelegate.isLocalModelReady ? "On-device: ready" : "On-device: on"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let path = appDelegate.lastRecordingPath {
                Text("Last recording: \((path as NSString).lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if appDelegate.isTranscribing {
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appDelegate.isCleaningUp {
                Text("Cleaning up…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let transcript = appDelegate.lastTranscript {
                Divider()
                Text("Last transcript:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(transcript)
                    .font(.caption)
                    .lineLimit(4)
            } else if let error = appDelegate.transcriptionError {
                Divider()
                Text("Transcription failed: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()
            Button("Settings…") {
                appDelegate.showSettings()
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
