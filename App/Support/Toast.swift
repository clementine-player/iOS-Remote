import SwiftUI

/// Short messages that come and go, like Android's toasts. Each replaces the one before, so
/// tapping through modes shows the latest.
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
    }

    private(set) var current: Toast?
    private var dismissal: Task<Void, Never>?

    func show(_ text: LocalizedStringResource, duration: Duration = .seconds(2)) {
        show(verbatim: String(localized: text), duration: duration)
    }

    func show(verbatim text: String, duration: Duration = .seconds(2)) {
        let toast = Toast(text: text)
        current = toast
        AccessibilityNotification.Announcement(text).post()
        dismissal?.cancel()
        dismissal = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, current == toast else { return }
            current = nil
        }
    }
}

/// Shows the toast center's toast at the top of [content].
struct ToastOverlay: ViewModifier {
    let toasts: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = toasts.current {
                Text(toast.text)
                    .textStyle(.bodyMedium)
                    .foregroundStyle(Palette.onSurface)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Metrics.space4)
                    .padding(.vertical, Metrics.space3)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, Metrics.space6)
                    .padding(.top, Metrics.space2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: toasts.current)
    }
}

extension View {
    func toasts(_ toasts: ToastCenter) -> some View {
        modifier(ToastOverlay(toasts: toasts))
    }
}
