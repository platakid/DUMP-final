import SwiftUI

@main
@MainActor
struct DUMPApp: App {

    @UIApplicationDelegateAdaptor(PrivacyDelegate.self)
    private var delegate

    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onAppear {
                    delegate.model = model
                    delegate.refreshCapture()
                }
        }
    }
}

@MainActor
final class PrivacyDelegate: NSObject, UIApplicationDelegate {

    weak var model: AppModel?

    private var observers: [NSObjectProtocol] = []
    private let shieldTag = 70020715

    // Prevent duplicate background handling.
    private var backgroundLockHandled = false

    // MARK: - Launch

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        /*
         TEMPORARY SCENE DEACTIVATION

         Face ID and other iOS system interfaces can temporarily
         deactivate the scene.

         IMPORTANT:
         We hide the application's contents, but we DO NOT lock
         the vault and DO NOT cancel the authentication session.
         */
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIScene.willDeactivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                MainActor.assumeIsolated {
                    self?.cover()
                    self?.model?.suspendCameraCapture()
                }
            }
        )

        /*
         SCENE ACTIVE AGAIN

         Face ID can temporarily deactivate the scene.

         Once iOS tells us the scene is active again, the privacy
         shield can be removed as long as screen capture is not active.
         */
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                MainActor.assumeIsolated {
                    self?.backgroundLockHandled = false
                    self?.sceneDidActivate()
                }
            }
        )

        /*
         Protected data becoming unavailable is a genuine
         security event.

         In this situation the vault should immediately lock.
         */
        observers.append(
            NotificationCenter.default.addObserver(
                forName:
                    UIApplication
                        .protectedDataWillBecomeUnavailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                MainActor.assumeIsolated {
                    self?.cover()
                    self?.model?.lock()
                }
            }
        )

        /*
         Screen recording / mirroring changed.
         */
        observers.append(
            NotificationCenter.default.addObserver(
                forName:
                    UIScreen.capturedDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                MainActor.assumeIsolated {
                    self?.refreshCapture()
                }
            }
        )

        /*
         Screenshot warning.

         iOS does not allow an application to retroactively
         prevent a screenshot once the screenshot event fires,
         so we notify the user.
         */
        observers.append(
            NotificationCenter.default.addObserver(
                forName:
                    UIApplication
                        .userDidTakeScreenshotNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                MainActor.assumeIsolated {
                    self?.showScreenshotNotice()
                }
            }
        )

        return true
    }

    deinit {

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Windows

    private var windows: [UIWindow] {

        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    // MARK: - Privacy Shield

    private func cover() {

        for window in windows
        where window.viewWithTag(shieldTag) == nil {

            let shield = UIView(
                frame: window.bounds
            )

            shield.tag = shieldTag

            shield.backgroundColor =
                .systemBackground

            shield.autoresizingMask = [
                .flexibleWidth,
                .flexibleHeight
            ]

            shield.isUserInteractionEnabled = true

            let label = UILabel()

            label.text = "DUMP"

            label.font = .systemFont(
                ofSize: 28,
                weight: .semibold
            )

            label.translatesAutoresizingMaskIntoConstraints =
                false

            shield.addSubview(label)

            NSLayoutConstraint.activate([

                label.centerXAnchor.constraint(
                    equalTo:
                        shield.centerXAnchor
                ),

                label.centerYAnchor.constraint(
                    equalTo:
                        shield.centerYAnchor
                )
            ])

            window.addSubview(shield)
        }

        CATransaction.flush()
    }

    private func uncover() {

        windows.forEach {

            $0.viewWithTag(shieldTag)?
                .removeFromSuperview()
        }
    }

    // MARK: - Scene Activation

    private func sceneDidActivate() {

        /*
         NEVER reveal the application while iOS reports
         active screen capture / mirroring.
         */
        if UIScreen.screens.contains(
            where: \.isCaptured
        ) {

            cover()
            model?.lock()
            return
        }

        /*
         Scene is active and no screen capture is occurring.

         This is important for Face ID:
         Face ID may temporarily deactivate the scene, but that
         should only display the privacy shield.

         It must NOT destroy the authentication session.
         */
        uncover()
    }

    // MARK: - Screen Capture

    func refreshCapture() {

        if UIScreen.screens.contains(
            where: \.isCaptured
        ) {

            cover()
            model?.lock()

            return
        }

        /*
         onAppear can call this method.

         Only reveal the application if iOS says it is
         currently active.
         */
        if UIApplication.shared.applicationState == .active {

            uncover()
        }
    }

    // MARK: - Screenshot Notice

    private func showScreenshotNotice() {

        guard
            UIApplication.shared.applicationState == .active,

            !UIScreen.screens.contains(
                where: \.isCaptured
            ),

            let window =
                windows.first(
                    where: \.isKeyWindow
                )

        else {
            return
        }

        let notice = UILabel()

        notice.text =
            "Screenshot detected. iOS has already captured this screen."

        notice.numberOfLines = 0

        notice.textAlignment =
            .center

        notice.font =
            .preferredFont(
                forTextStyle: .footnote
            )

        notice.backgroundColor =
            .secondarySystemBackground

        notice.layer.cornerRadius = 14

        notice.clipsToBounds = true

        notice.translatesAutoresizingMaskIntoConstraints =
            false

        window.addSubview(notice)

        NSLayoutConstraint.activate([

            notice.leadingAnchor.constraint(
                equalTo:
                    window.safeAreaLayoutGuide.leadingAnchor,
                constant: 16
            ),

            notice.trailingAnchor.constraint(
                equalTo:
                    window.safeAreaLayoutGuide.trailingAnchor,
                constant: -16
            ),

            notice.topAnchor.constraint(
                equalTo:
                    window.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),

            notice.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 64
            )
        ])

        UIAccessibility.post(
            notification: .announcement,
            argument: notice.text
        )

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 6
        ) {

            notice.removeFromSuperview()
        }
    }

    // MARK: - UIApplication Lifecycle

    func applicationWillResignActive(
        _ application: UIApplication
    ) {

        /*
         CRITICAL FOR FACE ID

         DO NOT call model.lock() here.

         Face ID can temporarily cause the application to resign
         active status.

         Locking here would:
         - increment AppModel.generation
         - revoke SessionLease
         - cancel LAContext
         - invalidate the successful Face ID result

         We therefore ONLY hide sensitive content.
         */
        cover()

        model?.suspendCameraCapture()
    }

    func applicationDidEnterBackground(
        _ application: UIApplication
    ) {

        /*
         REAL BACKGROUND TRANSITION

         Unlike resignActive, this means the application actually
         entered the background.

         Now it is appropriate to destroy the security session.
         */

        cover()

        /*
         Prevent duplicate lifecycle callbacks from locking the
         same session multiple times.
         */
        guard !backgroundLockHandled else {
            return
        }

        backgroundLockHandled = true

        model?.lock()
    }

    func applicationDidBecomeActive(
        _ application: UIApplication
    ) {

        /*
         Application is active again.

         This also happens after Face ID disappears.
         */

        backgroundLockHandled = false

        sceneDidActivate()
    }
}