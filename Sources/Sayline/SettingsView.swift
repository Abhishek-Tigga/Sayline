import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appDelegate: AppDelegate
    @State private var apiKeyInput: String = KeychainStore.load() ?? ""
    @State private var apiKeySaved = false

    var body: some View {
        Form {
            Section("Transcription") {
                Toggle("Use On-Device Transcription", isOn: $appDelegate.useLocalTranscription)

                if appDelegate.isLocalModelDownloading {
                    Text("Downloading local model (one-time)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if appDelegate.useLocalTranscription && appDelegate.isLocalModelReady {
                    Text("Local model ready.")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                SecureField("Groq API Key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Key") {
                        KeychainStore.save(apiKeyInput)
                        apiKeySaved = true
                    }
                    .disabled(apiKeyInput.isEmpty)

                    if apiKeySaved {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Link("Get a free key at console.groq.com", destination: URL(string: "https://console.groq.com")!)
                    .font(.caption2)
            }

            Section("Dictation") {
                Picker("Default Style", selection: $appDelegate.dictationStyle) {
                    ForEach(DictationStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appDelegate.launchAtLogin },
                    set: { appDelegate.launchAtLogin = $0 }
                ))
            }

            Section("About") {
                Text("Sayline v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("View on GitHub", destination: URL(string: "https://github.com/Abhishek-Tigga/Sayline")!)
                    .font(.caption)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
