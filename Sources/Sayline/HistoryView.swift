import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appDelegate: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            if appDelegate.historyEntries.isEmpty {
                Text("No dictations yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appDelegate.historyEntries) { entry in
                    HistoryRow(entry: entry)
                }
                HStack {
                    Spacer()
                    Button("Clear History") {
                        appDelegate.clearHistory()
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// A short label per mode, or nil for entries written before work
    /// mode existed. A fallback is labelled as such rather than as Clean —
    /// the user asked for a rewrite and did not get one, and that is worth
    /// seeing in the list.
    private static func modeBadge(for mode: String?) -> (label: String, tint: Color)? {
        guard let mode else { return nil }
        if mode.hasPrefix("work → fell back") { return ("fell back", .orange) }
        if mode.hasPrefix("work (retry") { return ("work · retried", .teal) }
        if mode.hasPrefix("work") { return ("work", .teal) }
        if mode == "verbatim" { return ("verbatim", .secondary) }
        return ("clean", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Self.formatter.string(from: entry.timestamp))
                Text("·")
                Text(entry.usedLocal ? "local" : "cloud")
                // Which mode produced this. Recorded since work mode
                // shipped; entries from before it decode with `mode` nil
                // and show nothing rather than a wrong label.
                if let badge = Self.modeBadge(for: entry.mode) {
                    Text("·")
                    Text(badge.label)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badge.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(badge.tint)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(entry.text)
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}
