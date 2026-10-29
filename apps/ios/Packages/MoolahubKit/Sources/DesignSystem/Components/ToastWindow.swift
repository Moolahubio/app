import SwiftUI
import UIKit

// The toast's host (A8.23, A9.5, B1.10). A toast sits centred 8 pt below the
// top safe area (y 70 on iPhone 17 Pro), which is inside the navigation bar's
// band. An overlay on a screen is drawn UNDER that screen's navigation bar, so
// on a pushed screen the inline title (Goal detail, Group detail, Profile,
// Security) would draw over the toast (measured on iOS 26.5 by the Savings
// engineer). `.toast($message)` therefore hands the message to `ToastWindow`:
// one window just above the app's own that draws only the toast. It is above
// every sheet too (Developer settings' "Saved.").

/// Shows `message` as a toast for 3 seconds (tap to dismiss; a new one
/// replaces the old; posted as an announcement). The modifier hands the
/// message to the toast window and sets the binding back to nil at once.
struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: message, initial: true) { _, new in
                guard let new else { return }
                ToastWindow.shared.show(new)
                message = nil
            }
    }
}

/// What the toast window shows, and where the toast is drawn (window
/// coordinates), so only a touch on the toast reaches the window.
@MainActor
@Observable
final class ToastWindowModel {
    var message: String?
    @ObservationIgnored var toastFrame: CGRect = .null
}

/// One window above the app's own (`UIWindow.Level.normal + 1`). It is hidden
/// while no toast shows, never becomes key, passes every touch outside the
/// toast through to the app, and hides at once when the scene leaves the
/// foreground, so a toast never shows over the privacy cover (B1.2).
@MainActor
final class ToastWindow {
    static let shared = ToastWindow()

    private let model = ToastWindowModel()
    private var window: ToastUIWindow?
    private var hideTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ToastWindow.shared.hideNow() }
        }
    }

    func show(_ message: String) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        hideTask?.cancel()
        let window = window(for: scene)
        window.isHidden = false
        model.message = message
    }

    private func window(for scene: UIWindowScene) -> ToastUIWindow {
        if let window, window.windowScene === scene { return window }
        window?.isHidden = true
        let window = ToastUIWindow(windowScene: scene)
        window.model = model
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: ToastWindowContent(model: model) {
            ToastWindow.shared.hideWhenIdle()
        })
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true
        self.window = window
        return window
    }

    /// After the toast's exit animation (`Motion.exit`, 0.2 s).
    private func hideWhenIdle() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.model.message == nil else { return }
            self.window?.isHidden = true
        }
    }

    private func hideNow() {
        hideTask?.cancel()
        model.message = nil
        model.toastFrame = .null
        window?.isHidden = true
    }

    #if DEBUG
    /// Debug builds only: this launch argument keeps every toast (Savings,
    /// Groups, Account, Developer settings) on screen after its 3 seconds and
    /// ignores the tap, so a UI test on a busy Mac can screenshot it and check
    /// where it sits (B1.10, B3.7, B3.12). A newer toast still replaces it.
    /// Release builds always use the 3 seconds.
    static let holdLaunchArgument = "-mh-hold-toasts"

    static var holdsToasts: Bool {
        ProcessInfo.processInfo.arguments.contains(holdLaunchArgument)
    }
    #endif
}

/// Touches reach the window only on the toast (a tap dismisses it).
final class ToastUIWindow: UIWindow {
    weak var model: ToastWindowModel?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let frame = model?.toastFrame, frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The toast window's content: the toast with its motion on a full-screen
/// clear view (so it sits 8 pt below the top safe area), plus the same toast
/// laid out hidden in the same place to report its frame for hit testing.
private struct ToastWindowContent: View {
    @Bindable var model: ToastWindowModel
    let onIdle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(Motion.reducedCrossfade)
        }
        return .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(y: -12)).animation(Motion.standard),
            removal: AnyTransition.opacity.animation(Motion.exit)
        )
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                if let shown = model.message {
                    Toast(shown)
                        .padding(.horizontal, Spacing.screenGutter)
                        .padding(.top, Spacing.space2)
                        .transition(transition)
                        .onTapGesture { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if let shown = model.message {
                    Toast(shown)
                        .hidden()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            model.toastFrame = frame
                        }
                        .padding(.horizontal, Spacing.screenGutter)
                        .padding(.top, Spacing.space2)
                }
            }
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: model.message)
            .task(id: model.message) {
                guard let shown = model.message else { return }
                AccessibilityNotification.Announcement(shown).post()
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, model.message == shown, !holds else { return }
                model.message = nil
            }
            .onChange(of: model.message) { _, new in
                if new == nil {
                    model.toastFrame = .null
                    onIdle()
                }
            }
    }

    private var holds: Bool {
        #if DEBUG
        return ToastWindow.holdsToasts
        #else
        return false
        #endif
    }

    private func dismiss() {
        guard !holds else { return }
        model.message = nil
    }
}
