import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appDelegate: AppDelegate
    @State private var apiKeyInput: String = KeychainStore.load() ?? ""
    @State private var apiKeySaved = false

    var body: some View {
        // Scrollable, so the content's height is never a demand the window
        // has to satisfy. Settings has grown twice this week and will
        // again; a fixed window plus unbounded content is what crashed.
        ScrollView {
            settingsForm
        }
    }

    private var settingsForm: some View {
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
                        APIKeyProvider.invalidateCache()
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

            Section("Hotkey") {
                Toggle("Always insert my exact words", isOn: $appDelegate.alwaysVerbatim)
                Text("Skips both Clean and Work. Nothing is rewritten or tidied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Default to Work mode", isOn: $appDelegate.defaultModeIsWork)
                    .disabled(appDelegate.alwaysVerbatim)
                Text(appDelegate.defaultModeIsWork
                     ? "Holding rewrites for clarity. Add \(appDelegate.hotkeyOption.shortSymbol)+⌘ to keep your own sentences."
                     : "Holding tidies what you said. Add \(appDelegate.hotkeyOption.shortSymbol)+⌘ to rewrite for clarity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Picker("Hold to Talk", selection: $appDelegate.hotkeyOption) {
                    ForEach(HotkeyOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Text("Takes effect immediately, even mid-session.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input Device", selection: Binding(
                    get: { appDelegate.preferredInputDeviceUID ?? "" },
                    set: { appDelegate.preferredInputDeviceUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Automatic (System Default)").tag("")
                    ForEach(AudioDeviceLister.inputDevices()) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Text("Automatic follows whatever macOS considers the default input — e.g. it switches to AirPods automatically when connected. Pin a specific device here to override that.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Calendars") {
                CalendarAccountsSettings()
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


/// The account scope, editable after the one-time card is gone.
///
/// The card offers this during onboarding, but a choice made before anyone
/// has used the feature needs a way back — so it lives here too, with room
/// for the addresses the card has to truncate.
private struct CalendarAccountsSettings: View {
    @State private var accounts: [ConnectedAccount] = []
    @State private var refusal: String?
    private let store = MeetingStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if accounts.isEmpty {
                Text("No calendar accounts are connected to this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Sayline reads meetings from these accounts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(accounts) { account in
                    Toggle(account.label, isOn: binding(for: account))
                }
                if let refusal {
                    Text(refusal).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { accounts = store.connectedAccounts() }
    }

    private func binding(for account: ConnectedAccount) -> Binding<Bool> {
        Binding(
            get: { account.isSelected },
            set: { enabled in
                let accepted = CalendarScope.set(account.id, enabled: enabled,
                                                 allKnown: accounts.map(\.id))
                refusal = accepted ? nil : "Keep at least one account on."
                accounts = store.connectedAccounts()
            }
        )
    }
}
