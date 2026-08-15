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

// MARK: - KioskWindow
// Intercepts all touch events globally to reset the inactivity timer
// WITHOUT attaching UIGestureRecognizers that cancel WKWebView touch/click events.
final class KioskWindow: UIWindow {
    var onUserInteraction: (() -> Void)?

    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)
        if event.type == .touches, let touches = event.allTouches {
            for touch in touches where touch.phase == .began {
                onUserInteraction?()
            }
        }
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    // MARK: - Bootstrap

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Prevent iPad from sleeping (kiosk mode)
        UIApplication.shared.isIdleTimerDisabled = true

        let kioskWin = KioskWindow(frame: UIScreen.main.bounds)
        kioskWin.backgroundColor = .black
        kioskWin.onUserInteraction = { [weak self] in
            self?.resetInactivityTimer()
        }
        window = kioskWin
        window?.makeKeyAndVisible()

        let rawIP = UserDefaults.standard.string(forKey: "kioskIP") ?? ""
        let savedIP = sanitizeIP(rawIP)

        if savedIP.isEmpty {
            // Try Bonjour hostname or prompt
            let autoHost = "MacBook-Air-de-Jose.local"
            UserDefaults.standard.set(autoHost, forKey: "kioskIP")
            startScreensaver(serverIP: autoHost)
        } else {
            startScreensaver(serverIP: savedIP)
        }

        return true
    }

    private func resetInactivityTimer() {
        if let kiosk = window?.rootViewController as? KioskViewController {
            startInactivityTimer(serverIP: kiosk.serverIP)
        }
    }

    // MARK: - Flow control

    /// Shows the native screensaver. When user taps, transitions to kiosk.
    func startScreensaver(serverIP: String) {
        let cleanIP = sanitizeIP(serverIP)
        let screensaver = NativeScreensaverViewController()
        screensaver.serverBaseURL = "http://\(cleanIP):3001"
        screensaver.serverIP = cleanIP
        screensaver.onStart = { [weak self] in
            self?.startKiosk(serverIP: cleanIP)
        }
        screensaver.onConfigureIP = { [weak self, weak screensaver] in
            self?.presentIPConfig(from: screensaver)
        }
        window?.rootViewController = screensaver
    }

    /// Shows the WKWebView kiosk. After inactivity, returns to screensaver.
    func startKiosk(serverIP: String) {
        let cleanIP = sanitizeIP(serverIP)
        let kiosk = KioskViewController()
        kiosk.serverIP = cleanIP

        // Transition with a clean crossfade
        let transition = CATransition()
        transition.duration = 0.5
        transition.type = CATransitionType(rawValue: CATransitionType.fade.rawValue)
        window?.layer.add(transition, forKey: nil)
        window?.rootViewController = kiosk

        // Start inactivity timer: after 3 minutes with no interaction → screensaver
        startInactivityTimer(serverIP: cleanIP)
    }

    // MARK: - Inactivity / screensaver return

    private var inactivityTimer: Timer?
    private let inactivityTimeout: TimeInterval = 3 * 60 // 3 minutes
    private var lastKioskIP: String = ""

    private func startInactivityTimer(serverIP: String) {
        lastKioskIP = sanitizeIP(serverIP)
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

    func presentIPConfig(from viewController: UIViewController?) {
        let currentSaved = sanitizeIP(UserDefaults.standard.string(forKey: "kioskIP") ?? "MacBook-Air-de-Jose.local")
        let defaultPromptIP = currentSaved.isEmpty ? "MacBook-Air-de-Jose.local" : currentSaved
        let alert = UIAlertController(
            title: "⚙️ Configuración Servidor",
            message: "Ingresa la IP o nombre de tu Mac:\n(ej: \(defaultPromptIP) o 192.168.1.119)",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.text = defaultPromptIP
            tf.keyboardType = .numbersAndPunctuation
            tf.placeholder = "192.168.1.119"
        }
        alert.addAction(UIAlertAction(title: "Conectar", style: .default) { [weak self] _ in
            let rawInput = alert.textFields?.first?.text ?? defaultPromptIP
            let finalIP = sanitizeIP(rawInput.isEmpty ? defaultPromptIP : rawInput)
            UserDefaults.standard.set(finalIP, forKey: "kioskIP")
            self?.startScreensaver(serverIP: finalIP)
        })

        if let vc = viewController {
            vc.present(alert, animated: true)
        } else {
            let blankVC = UIViewController()
            blankVC.view.backgroundColor = .black
            window?.rootViewController = blankVC
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                blankVC.present(alert, animated: true)
            }
        }
    }
}

// MARK: - IP Sanitizer Helper

func sanitizeIP(_ input: String) -> String {
    var cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
    cleaned = cleaned.replacingOccurrences(of: "http://", with: "")
    cleaned = cleaned.replacingOccurrences(of: "https://", with: "")
    if let colonIndex = cleaned.firstIndex(of: ":") {
        cleaned = String(cleaned[..<colonIndex])
    }
    if let slashIndex = cleaned.firstIndex(of: "/") {
        cleaned = String(cleaned[..<slashIndex])
    }
    return cleaned
}
