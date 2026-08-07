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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Self.formatter.string(from: entry.timestamp))
                Text("·")
                Text(entry.usedLocal ? "local" : "cloud")
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
