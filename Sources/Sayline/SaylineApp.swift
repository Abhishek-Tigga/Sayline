import SwiftUI

@main
struct SaylineApp: App {
    var body: some Scene {
        MenuBarExtra("Sayline", systemImage: "mic.fill") {
            MenuBarContentView()
        }
    }
}
