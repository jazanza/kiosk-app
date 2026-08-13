import UIKit

// MARK: - AppDelegate
//
// App entry point. Orchestrates the two-phase kiosk experience:
//
//   Phase 1 — NativeScreensaverViewController
//     Full-screen native slideshow. Fetches media from /api/screensaver.
//     Videos via AVPlayer (no iOS 9 autoplay restrictions).
//     Images via Ken Burns CoreAnimation.
//     User taps → fade out → Phase 2.
//
//   Phase 2 — KioskViewController (WKWebView)
//     Loads http://IP:3001/kiosk-legacy.
//     Native camera bridge, auto-reconnect, connecting overlay.
//     After inactivity (3 min) → returns to Phase 1.
//
// IP configuration:
//   Stored in UserDefaults["kioskIP"].
//   If not set, an alert is presented before Phase 2 starts.
//   Long-press top-right corner (3s) in Phase 2 to reconfigure.

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    // MARK: - Bootstrap

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Prevent iPad from sleeping (kiosk mode)
        UIApplication.shared.isIdleTimerDisabled = true

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .black

        let savedIP = UserDefaults.standard.string(forKey: "kioskIP") ?? ""

        if savedIP.isEmpty {
            // First launch: ask for IP, then start screensaver
            presentIPConfig(from: nil)
        } else {
            startScreensaver(serverIP: savedIP)
        }

        window?.makeKeyAndVisible()
        return true
    }

    // MARK: - Flow control

    /// Shows the native screensaver. When user taps, transitions to kiosk.
    func startScreensaver(serverIP: String) {
        let screensaver = NativeScreensaverViewController()
        screensaver.serverBaseURL = "http://\(serverIP):3001"
        screensaver.onStart = { [weak self] in
            self?.startKiosk(serverIP: serverIP)
        }
        window?.rootViewController = screensaver
    }

    /// Shows the WKWebView kiosk. After inactivity, returns to screensaver.
    func startKiosk(serverIP: String) {
        let kiosk = KioskViewController()
        kiosk.serverIP = serverIP

        // Transition with a clean crossfade
        let transition = CATransition()
        transition.duration = 0.5
        transition.type = CATransitionType(rawValue: CATransitionType.fade.rawValue)
        window?.layer.add(transition, forKey: nil)
        window?.rootViewController = kiosk

        // Start inactivity timer: after 3 minutes with no interaction → screensaver
        startInactivityTimer(serverIP: serverIP)
    }

    // MARK: - Inactivity / screensaver return

    private var inactivityTimer: Timer?
    private let inactivityTimeout: TimeInterval = 3 * 60 // 3 minutes
    private var lastKioskIP: String = ""

    private func startInactivityTimer(serverIP: String) {
        lastKioskIP = serverIP
        inactivityTimer?.invalidate()
        // Use selector-based Timer for iOS 9 compatibility (closure Timer is iOS 10+)
        inactivityTimer = Timer.scheduledTimer(
            timeInterval: inactivityTimeout,
            target: self,
            selector: #selector(returnToScreensaverFromTimer),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func returnToScreensaverFromTimer() {
        guard !lastKioskIP.isEmpty else { return }
        startScreensaver(serverIP: lastKioskIP)
    }

    // MARK: - IP Configuration alert

    private func presentIPConfig(from viewController: UIViewController?) {
        let savedIP = UserDefaults.standard.string(forKey: "kioskIP") ?? "192.168.0.105"
        let alert = UIAlertController(
            title: "⚙️ Configuración",
            message: "Ingresa la IP del servidor Chin Chin\n(ej: 192.168.0.105)",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.text = savedIP
            tf.keyboardType = .numbersAndPunctuation
            tf.placeholder = "192.168.0.105"
        }
        alert.addAction(UIAlertAction(title: "Conectar", style: .default) { [weak self] _ in
            let ip = alert.textFields?.first?.text ?? savedIP
            let finalIP = ip.isEmpty ? savedIP : ip
            UserDefaults.standard.set(finalIP, forKey: "kioskIP")
            self?.startScreensaver(serverIP: finalIP)
        })

        // Present on a transparent root VC so the alert shows before anything else loads
        if viewController == nil {
            let blankVC = UIViewController()
            blankVC.view.backgroundColor = .black
            window?.rootViewController = blankVC
            // Small delay to ensure the window is visible before presenting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                blankVC.present(alert, animated: true)
            }
        } else {
            viewController?.present(alert, animated: true)
        }
    }
}
