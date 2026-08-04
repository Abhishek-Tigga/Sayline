import SwiftUI

enum RecordingIndicatorState: Equatable {
    case recording
    case transcribing
    case cleaningUp
}

final class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingIndicatorState = .recording
    @Published var style: DictationStyle = .clean
    @Published var focusedAppInfo: FocusedAppInfo?
}

struct RecordingIndicatorView: View {
    @ObservedObject var viewModel: IndicatorViewModel

    var body: some View {
        VStack(spacing: 8) {
            if viewModel.state == .recording {
                debugAppInfoBlock
                styleRow
            }
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Temporary, deliberately visible while building context-aware
    /// formatting — lets us verify detection live instead of guessing.
    /// Will come out (or move somewhere less prominent) once the UI gets
    /// a real pass later.
    private var debugAppInfoBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            let info = viewModel.focusedAppInfo
            Text("App: \(info?.name ?? "—")").lineLimit(1)
            Text("Bundle: \(info?.bundleID ?? "—")").lineLimit(1)
            Text("Window: \(info?.windowTitle ?? "—")").lineLimit(1)
            Text("Context: \(info?.context.rawValue ?? "—")").bold()
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
    }

    private var styleRow: some View {
        HStack(spacing: 4) {
            ForEach(DictationStyle.allCases, id: \.self) { style in
                Text(style.displayName)
                    .font(.system(size: 11, weight: style == viewModel.style ? .bold : .regular))
                    .foregroundStyle(style == viewModel.style ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(style == viewModel.style ? Color.primary.opacity(0.12) : .clear)
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
    }

    private var pill: some View {
        HStack(spacing: 8) {
            icon
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(.regularMaterial))
    }

    private var label: String {
        switch viewModel.state {
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .cleaningUp: return "Cleaning up…"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch viewModel.state {
        case .recording:
            PulsingDot()
        case .transcribing, .cleaningUp:
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .scaleEffect(isPulsing ? 1.3 : 0.85)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
