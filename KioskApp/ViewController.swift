import UIKit
import WebKit

// MARK: - KioskViewController
//
// Manages the WKWebView that hosts the Beer Matchmaker web app.
// Responsibilities:
//   - Load and reload the kiosk web page
//   - Native selfie camera via JS bridge (window.webkit.messageHandlers.cameraHandler)
//   - Auto-reconnect when the server comes back online (via NetworkMonitor)
//   - Show a native "Connecting..." overlay instead of a blank screen
//   - Hidden settings button (long press top-right corner, 3s)

final class KioskViewController: UIViewController,
                                  WKScriptMessageHandler,
                                  UIImagePickerControllerDelegate,
                                  UINavigationControllerDelegate,
                                  WKNavigationDelegate {

    // MARK: - Public config

    /// Server IP, set by AppDelegate after user configures it.
    /// NOTE: didSet calls loadKiosk() only after the view is loaded to prevent
    /// force-unwrap crash on webView before viewDidLoad() runs.
    var serverIP: String = "" {
        didSet {
            UserDefaults.standard.set(serverIP, forKey: "kioskIP")
            networkMonitor?.stop()
            networkMonitor = NetworkMonitor(host: serverIP)
            setupNetworkMonitor()
            // Only load if the view hierarchy is ready
            if isViewLoaded {
                loadKiosk()
            }
        }
    }

    var serverBaseURL: String { "http://\(serverIP):3001" }

    // MARK: - Private UI

    private var webView: WKWebView?  // Optional — set in viewDidLoad
    private var loadingTimer: Timer?

    // Native "Connecting..." overlay — shown instead of blank screen
    private let connectingOverlay = UIView()
    private let connectingLabel = UILabel()
    private let connectingSpinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView()
        s.style = .whiteLarge
        s.color = .white
        return s
    }()
    private let retryButton = UIButton(type: .system)
    private let changeIPButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)

    // MARK: - Network

    private var networkMonitor: NetworkMonitor?
    private var retryTimer: Timer?
    private var isPageLoaded = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        setupConnectingOverlay()
        setupSettingsButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // If IP already configured (coming back from screensaver), load directly
        if !serverIP.isEmpty {
            loadKiosk()
        }
    }

    override var prefersStatusBarHidden: Bool { return true }

    // MARK: - WebView setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // JS Bridges: camera and navigation/screensaver flow
        contentController.add(self, name: "cameraHandler")
        contentController.add(self, name: "kioskHandler")
        config.userContentController = contentController

        // Enable video inline (required for any video playback in WKWebView)
        config.allowsInlineMediaPlayback = true
        if #available(iOS 10.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
        } else {
            config.mediaPlaybackRequiresUserAction = false
        }

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView?.navigationDelegate = self
        webView?.scrollView.bounces = false
        webView?.scrollView.isScrollEnabled = false
        webView?.isOpaque = false
        webView?.backgroundColor = .black
        view.addSubview(webView!)
    }

    // MARK: - Connecting overlay

    private func setupConnectingOverlay() {
        connectingOverlay.frame = view.bounds
        connectingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        connectingOverlay.backgroundColor = .black
        view.addSubview(connectingOverlay)

        connectingSpinner.translatesAutoresizingMaskIntoConstraints = false
        connectingLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        changeIPButton.translatesAutoresizingMaskIntoConstraints = false

        connectingLabel.text = "Conectando con el servidor..."
        connectingLabel.font = UIFont(name: "AvenirNext-Medium", size: 20) ?? UIFont.systemFont(ofSize: 20)
        connectingLabel.textColor = .white
        connectingLabel.textAlignment = .center
        connectingLabel.numberOfLines = 3

        retryButton.setTitle("🔄 Reintentar", for: .normal)
        retryButton.titleLabel?.font = UIFont(name: "AvenirNext-Bold", size: 18) ?? UIFont.boldSystemFont(ofSize: 18)
        retryButton.tintColor = UIColor(red: 0.8, green: 1.0, blue: 0.0, alpha: 1.0)
        retryButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        retryButton.layer.cornerRadius = 12
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)

        changeIPButton.setTitle("⚙️ Cambiar IP", for: .normal)
        changeIPButton.titleLabel?.font = UIFont(name: "AvenirNext-Bold", size: 18) ?? UIFont.boldSystemFont(ofSize: 18)
        changeIPButton.tintColor = .white
        changeIPButton.backgroundColor = UIColor.white.withAlphaComponent(0.20)
        changeIPButton.layer.cornerRadius = 12
        changeIPButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        changeIPButton.isHidden = true
        changeIPButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)

        connectingOverlay.addSubview(connectingSpinner)
        connectingOverlay.addSubview(connectingLabel)
        connectingOverlay.addSubview(retryButton)
        connectingOverlay.addSubview(changeIPButton)

        NSLayoutConstraint.activate([
            connectingSpinner.centerXAnchor.constraint(equalTo: connectingOverlay.centerXAnchor),
            connectingSpinner.centerYAnchor.constraint(equalTo: connectingOverlay.centerYAnchor, constant: -50),

            connectingLabel.topAnchor.constraint(equalTo: connectingSpinner.bottomAnchor, constant: 20),
            connectingLabel.leadingAnchor.constraint(equalTo: connectingOverlay.leadingAnchor, constant: 40),
            connectingLabel.trailingAnchor.constraint(equalTo: connectingOverlay.trailingAnchor, constant: -40),

            retryButton.topAnchor.constraint(equalTo: connectingLabel.bottomAnchor, constant: 30),
            retryButton.centerXAnchor.constraint(equalTo: connectingOverlay.centerXAnchor, constant: -110),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            changeIPButton.topAnchor.constraint(equalTo: connectingLabel.bottomAnchor, constant: 30),
            changeIPButton.centerXAnchor.constraint(equalTo: connectingOverlay.centerXAnchor, constant: 110),
            changeIPButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        connectingSpinner.startAnimating()
        showConnecting(message: "Conectando con el servidor...")
    }

    private func showConnecting(message: String) {
        connectingLabel.text = message
        connectingSpinner.startAnimating()
        retryButton.isHidden = true
        changeIPButton.isHidden = true
        UIView.animate(withDuration: 0.3) { self.connectingOverlay.alpha = 1 }
        connectingOverlay.isHidden = false
    }

    private func showRetry() {
        connectingLabel.text = "No se pudo conectar con:\n\(serverBaseURL)\n\nVerifica que la Mac y el iPad estén en la misma red Wi-Fi."
        connectingSpinner.stopAnimating()
        retryButton.isHidden = false
        changeIPButton.isHidden = false
    }

    private func hideConnecting() {
        UIView.animate(withDuration: 0.5, animations: {
            self.connectingOverlay.alpha = 0
        }) { _ in
            self.connectingOverlay.isHidden = true
        }
    }

    // MARK: - Invisible admin settings touch target

    private func setupSettingsButton() {
        // Invisible 80x80 touch target at top-right corner
        settingsButton.frame = CGRect(x: view.bounds.width - 80, y: 0, width: 80, height: 80)
        settingsButton.backgroundColor = .clear
        settingsButton.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(showSettings))
        longPress.minimumPressDuration = 2.0
        settingsButton.addGestureRecognizer(longPress)
        view.addSubview(settingsButton)
        view.bringSubviewToFront(settingsButton)
    }

    // MARK: - Load kiosk

    func loadKiosk() {
        guard !serverIP.isEmpty,
              let url = URL(string: "\(serverBaseURL)/kiosk-legacy") else {
            showSettings()
            return
        }

        isPageLoaded = false
        showConnecting(message: "Cargando Chin Chin Kiosk...")
        webView?.load(URLRequest(url: url))

        // Safety timeout: if page doesn't respond in 20s, show retry
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(timeInterval: 20.0, target: self, selector: #selector(onLoadTimeout), userInfo: nil, repeats: false)
    }

    @objc private func retryLoad() { loadKiosk() }

    @objc private func onLoadTimeout() {
        guard !isPageLoaded else { return }
        webView?.stopLoading()
        showRetry()
        scheduleAutoRetry()
    }

    // MARK: - Auto-retry every 30s when offline

    private func scheduleAutoRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(timeInterval: 30.0, target: self, selector: #selector(retryLoad), userInfo: nil, repeats: false)
    }

    // MARK: - NetworkMonitor

    private func setupNetworkMonitor() {
        networkMonitor?.onReachable = { [weak self] in
            guard let self = self, !self.isPageLoaded else { return }
            self.loadKiosk()
        }
        networkMonitor?.onUnreachable = { [weak self] in
            self?.showConnecting(message: "Sin conexión WiFi...")
        }
        networkMonitor?.start()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingTimer?.invalidate()
        retryTimer?.invalidate()
        isPageLoaded = true
        hideConnecting()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingTimer?.invalidate()
        isPageLoaded = false
        showRetry()
        scheduleAutoRetry()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadingTimer?.invalidate()
        isPageLoaded = false
        showRetry()
        scheduleAutoRetry()
    }

    // MARK: - Settings

    @objc func showSettings() {
        loadingTimer?.invalidate()
        retryTimer?.invalidate()
        let currentSaved = sanitizeIP(UserDefaults.standard.string(forKey: "kioskIP") ?? "MacBook-Air-de-Jose.local")
        let defaultPromptIP = currentSaved.isEmpty ? "MacBook-Air-de-Jose.local" : currentSaved
        let alert = UIAlertController(title: "⚙️ Servidor", message: "IP o nombre de tu Mac:\n(ej: \(defaultPromptIP))", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = defaultPromptIP
            tf.keyboardType = .numbersAndPunctuation
            tf.placeholder = "192.168.1.119"
        }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Conectar", style: .default) { [weak self] _ in
            let rawInput = alert.textFields?.first?.text ?? defaultPromptIP
            let finalIP = sanitizeIP(rawInput.isEmpty ? defaultPromptIP : rawInput)
            self?.serverIP = finalIP
        })
        present(alert, animated: true)
    }

    // MARK: - JS Bridge (WKScriptMessageHandler)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "cameraHandler",
           let msg = message.body as? String,
           msg == "openFrontCamera" {
            DispatchQueue.main.async { self.openFrontCamera() }
        } else if message.name == "kioskHandler",
                  let msg = message.body as? String,
                  msg == "returnToScreensaver" {
            DispatchQueue.main.async {
                (UIApplication.shared.delegate as? AppDelegate)?.startScreensaver(serverIP: self.serverIP)
            }
        }
    }

    // MARK: - Native camera

    func openFrontCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = UIImagePickerController.isCameraDeviceAvailable(.front) ? .front : .rear
        picker.delegate = self
        picker.showsCameraControls = true
        present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let originalImage = info[.originalImage] as? UIImage else { return }

        // Downscale image to 810x1080 to keep memory under 150KB and prevent WebKit crash on iOS 9
        let targetSize = CGSize(width: 810, height: 1080)
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        originalImage.draw(in: CGRect(origin: .zero, size: targetSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext() ?? originalImage
        UIGraphicsEndImageContext()

        guard let imageData = resized.jpegData(compressionQuality: 0.70) else { return }
        let base64 = imageData.base64EncodedString()

        let js = """
        (function() {
            var dataUri = 'data:image/jpeg;base64,\(base64)';
            if (typeof window.receiveNativePhoto === 'function') {
                window.receiveNativePhoto(dataUri);
            } else if (typeof window.generateStoryCanvas === 'function') {
                var img = new Image();
                img.onload = function() { window.generateStoryCanvas(img); };
                img.src = dataUri;
            }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}
