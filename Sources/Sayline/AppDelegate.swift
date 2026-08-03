import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var isRecording = false
    @Published var isAccessibilityTrusted = false
    @Published var isMicAuthorized = false
    @Published var lastRecordingPath: String?

    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager.onHotkeyDown = { [weak self] in
            DispatchQueue.main.async {
                self?.isRecording = true
                self?.audioRecorder.start()
            }
        }
        hotkeyManager.onHotkeyUp = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRecording = false
                self.audioRecorder.stop()
                self.lastRecordingPath = self.audioRecorder.lastRecordingURL?.path
            }
        }

        refreshAccessibilityStatus()

        audioRecorder.requestMicPermission { [weak self] granted in
            self?.isMicAuthorized = granted
        }
    }

    func refreshAccessibilityStatus() {
        isAccessibilityTrusted = AccessibilityPermission.isTrusted
        if isAccessibilityTrusted {
            hotkeyManager.start()
        }
    }

    func requestAccessibilityPermission() {
        AccessibilityPermission.requestIfNeeded()
    }
}
