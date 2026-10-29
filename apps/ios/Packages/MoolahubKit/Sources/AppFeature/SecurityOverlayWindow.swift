import Auth
import DesignSystem
import SwiftUI
import UIKit

// The lock screen and the privacy cover (DESIGN.md v2 B1.2, B1.3, A9.11)
// must sit above EVERYTHING the app draws, sheets included: B1.2 says the
// cover is "above everything" and J0.3 that it shows behind the Face ID HUD,
// and B1.3's lock must not leave an open money sheet readable and tappable
// over it. A view in the root's ZStack can't do that: every sheet is a UIKit
// presentation above the root's hosting view. So both live in this window,
// one level above the app's own windows (and above `ToastWindow`).
//
// - The privacy cover shows from `UIScene.willDeactivateNotification` (in
//   the same turn, never animated, so it is in place before iOS takes the
//   app-switcher snapshot) until `didActivateNotification`.
// - The lock screen shows while `AppLock.isLocked` (signed in). Becoming
//   active runs `AppLock.sceneDidBecomeActive()` BEFORE the cover goes, so a
//   relock is in place in the frame the cover leaves (A5.4, B1.3).
// - While neither shows, the window is hidden and every touch reaches the
//   app. While locked it is key, ends editing in the app (no keyboard over
//   the lock) and is modal for VoiceOver.

/// What the overlay window shows.
@MainActor
@Observable
final class SecurityOverlayModel {
    /// The scene is not active (app switcher, Control Center, a Face ID prompt).
    var coversScene = false
}

@MainActor
final class SecurityOverlayWindow {
    static let shared = SecurityOverlayWindow()

    /// Above the app's windows, the toast window and any alert window.
    static let level = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)

    private let model = SecurityOverlayModel()
    private var services: AppServices?
    private var window: SecurityOverlayUIWindow?
    private weak var appWindow: UIWindow?
    private var observers: [any NSObjectProtocol] = []
    private var hideTask: Task<Void, Never>?
    private var wasLocked = false

    private init() {}

    /// True while the lock screen or the privacy cover is up: the window
    /// takes every touch (nothing reaches the app underneath).
    var capturesTouches: Bool { model.coversScene || isLocked }

    private var isLocked: Bool {
        guard let services else { return false }
        return services.session.isSignedIn && services.appLock.isLocked
    }

    /// Called by `AppRootView` once its view is in a window. Idempotent.
    func install(on scene: UIWindowScene, appWindow: UIWindow, services: AppServices) {
        self.appWindow = appWindow
        guard window?.windowScene !== scene || self.services !== services else { return }
        self.services = services
        window?.isHidden = true
        let window = SecurityOverlayUIWindow(windowScene: scene)
        window.windowLevel = Self.level
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: SecurityOverlayContent(services: services, model: model))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true
        self.window = window
        observeScene()
        model.coversScene = scene.activationState != .foregroundActive
        observeLock()
        refresh()
    }

    private func observeScene() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecurityOverlayWindow.shared.sceneWillDeactivate() }
        })
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecurityOverlayWindow.shared.sceneDidEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecurityOverlayWindow.shared.sceneDidActivate() }
        })
    }

    private func sceneWillDeactivate() {
        // Never animated (B1.2): in place in the frame the scene leaves .active.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.coversScene = true }
        refresh()
    }

    private func sceneDidEnterBackground() {
        services?.appLock.sceneDidEnterBackground()
    }

    private func sceneDidActivate() {
        // Relock first, so the lock is in place before the cover goes.
        services?.appLock.sceneDidBecomeActive()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.coversScene = false }
        refresh()
    }

    /// Re-runs `refresh()` whenever the lock or the session changes.
    private func observeLock() {
        withObservationTracking {
            _ = isLocked
        } onChange: {
            Task { @MainActor in
                SecurityOverlayWindow.shared.refresh()
                SecurityOverlayWindow.shared.observeLock()
            }
        }
    }

    /// Shows or hides the window for the current lock and scene state. Runs
    /// on every scene change, from `AppRootView` when the session changes, and
    /// after any change of `AppLock.isLocked`.
    func refresh() {
        guard let window else { return }
        let locked = isLocked
        if locked && !wasLocked {
            // No keyboard of the app's over the lock screen.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        if capturesTouches {
            hideTask?.cancel()
            hideTask = nil
            window.isHidden = false
        } else if !window.isHidden, hideTask == nil {
            // After the lock's fade-out (Motion.standard, 0.3 s); touches
            // already pass through.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                self.hideTask = nil
                if !self.capturesTouches { self.window?.isHidden = true }
            }
        }
        window.accessibilityViewIsModal = locked
        if locked && !wasLocked {
            window.makeKey()
        } else if !locked && wasLocked {
            appWindow?.makeKey()
        }
        wasLocked = locked
    }
}

/// Touches reach this window only while it covers the app.
final class SecurityOverlayUIWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard SecurityOverlayWindow.shared.capturesTouches else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The overlay's content: the lock screen (zIndex 1) under the privacy
/// cover (zIndex 2), exactly as the root drew them before (B1.2, B1.3).
private struct SecurityOverlayContent: View {
    let services: AppServices
    @Bindable var model: SecurityOverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isLocked = services.session.isSignedIn && services.appLock.isLocked
        ZStack {
            Color.clear
            if isLocked {
                LockScreenView(services: services)
                    .transition(RootTransition.lockOverlay)
                    .zIndex(1)
            }
            if model.coversScene {
                // Never animated: in place in the frame the scene leaves .active (B1.2).
                PrivacyCover()
                    .transition(.identity)
                    .zIndex(2)
            }
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: isLocked)
        .environment(services)
        .environment(services.session)
        .environment(services.settings)
        .tint(Palette.ctaBackground)
    }
}

/// Hands `AppRootView`'s window and scene to the overlay once the root is on
/// screen.
struct SceneWindowReader: UIViewRepresentable {
    let onWindow: @MainActor (UIWindow) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onWindow: (@MainActor (UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
