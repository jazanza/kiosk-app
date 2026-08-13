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
    var serverIP: String = "" {
        didSet {
            UserDefaults.standard.set(serverIP, forKey: "kioskIP")
            networkMonitor?.stop()
            networkMonitor = NetworkMonitor(host: serverIP)
            setupNetworkMonitor()
            loadKiosk()
        }
    }

    var serverBaseURL: String { "http://\(serverIP):3001" }

    // MARK: - Private UI

    private var webView: WKWebView!
    private var loadingTimer: Timer?

    // Native "Connecting..." overlay — shown instead of blank screen
    private let connectingOverlay = UIView()
    private let connectingLabel = UILabel()
    private let connectingSpinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView()
        s.activityIndicatorViewStyle = .whiteLarge
        s.color = .white
        return s
    }()
    private let retryButton = UIButton(type: .system)

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

        // JS Bridge: intercept selfie button and redirect to native camera
        contentController.add(self, name: "cameraHandler")
        let cameraJS = """
        (function() {
            var interval = setInterval(function() {
                var btn = document.querySelector('.camera-label-btn');
                if (btn && !btn.dataset.hijacked) {
                    btn.dataset.hijacked = 'true';
                    btn.innerHTML = '📷 TOMAR SELFIE';
                    btn.onclick = function(e) {
                        e.preventDefault();
                        window.webkit.messageHandlers.cameraHandler.postMessage('openFrontCamera');
                    };
                }
            }, 500);
        })();
        """
        let script = WKUserScript(source: cameraJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        contentController.addUserScript(script)
        config.userContentController = contentController

        // Enable video inline (required for any video playback in WKWebView)
        config.allowsInlineMediaPlayback = true
        if #available(iOS 10.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
        } else {
            config.mediaPlaybackRequiresUserAction = false
        }

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false     // kiosk: disable scroll
        webView.isOpaque = false
        webView.backgroundColor = .black
        view.addSubview(webView)
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

        connectingLabel.text = "Conectando con el servidor..."
        connectingLabel.font = UIFont(name: "AvenirNext-Medium", size: 14) ?? UIFont.systemFont(ofSize: 14)
        connectingLabel.textColor = .lightGray
        connectingLabel.textAlignment = .center

        retryButton.setTitle("Reintentar", for: .normal)
        retryButton.titleLabel?.font = UIFont(name: "AvenirNext-Bold", size: 14) ?? UIFont.boldSystemFont(ofSize: 14)
        retryButton.tintColor = UIColor(red: 0.8, green: 1.0, blue: 0.0, alpha: 1.0)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)

        connectingOverlay.addSubview(connectingSpinner)
        connectingOverlay.addSubview(connectingLabel)
        connectingOverlay.addSubview(retryButton)

        NSLayoutConstraint.activate([
            connectingSpinner.centerXAnchor.constraint(equalTo: connectingOverlay.centerXAnchor),
            connectingSpinner.centerYAnchor.constraint(equalTo: connectingOverlay.centerYAnchor, constant: -20),
            connectingLabel.topAnchor.constraint(equalTo: connectingSpinner.bottomAnchor, constant: 16),
            connectingLabel.centerXAnchor.constraint(equalTo: connectingOverlay.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: connectingLabel.bottomAnchor, constant: 20),
            retryButton.centerXAnchor.constraint(equalTo: connectingOverlay.centerXAnchor),
        ])

        connectingSpinner.startAnimating()
        showConnecting(message: "Conectando con el servidor...")
    }

    private func showConnecting(message: String) {
        connectingLabel.text = message
        connectingSpinner.startAnimating()
        retryButton.isHidden = true
        UIView.animate(withDuration: 0.3) { self.connectingOverlay.alpha = 1 }
        connectingOverlay.isHidden = false
    }

    private func showRetry() {
        connectingLabel.text = "No se pudo conectar con el servidor"
        connectingSpinner.stopAnimating()
        retryButton.isHidden = false
    }

    private func hideConnecting() {
        UIView.animate(withDuration: 0.5, animations: {
            self.connectingOverlay.alpha = 0
        }) { _ in
            self.connectingOverlay.isHidden = true
        }
    }

    // MARK: - Hidden settings button

    private func setupSettingsButton() {
        let settingsBtn = UIButton(frame: CGRect(x: view.bounds.width - 100, y: 0, width: 100, height: 100))
        settingsBtn.backgroundColor = .clear
        settingsBtn.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(showSettings))
        longPress.minimumPressDuration = 3.0
        settingsBtn.addGestureRecognizer(longPress)
        view.addSubview(settingsBtn)
        view.bringSubviewToFront(settingsBtn)
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
        webView.load(URLRequest(url: url))

        // Safety timeout: if page doesn't respond in 20s, show retry
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(timeInterval: 20.0, target: self, selector: #selector(onLoadTimeout), userInfo: nil, repeats: false)
    }

    @objc private func retryLoad() { loadKiosk() }

    @objc private func onLoadTimeout() {
        guard !isPageLoaded else { return }
        webView.stopLoading()
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
        let currentIP = UserDefaults.standard.string(forKey: "kioskIP") ?? "192.168.0.105"
        let alert = UIAlertController(title: "⚙️ Servidor", message: "IP del servidor Node.js\n(ej: 192.168.0.105)", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = currentIP
            tf.keyboardType = .numbersAndPunctuation
            tf.placeholder = "192.168.0.105"
        }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Conectar", style: .default) { [weak self] _ in
            if let newIP = alert.textFields?.first?.text, !newIP.isEmpty {
                self?.serverIP = newIP
            }
        })
        present(alert, animated: true)
    }

    // MARK: - JS Bridge (WKScriptMessageHandler)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "cameraHandler",
           let msg = message.body as? String,
           msg == "openFrontCamera" {
            DispatchQueue.main.async { self.openFrontCamera() }
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
        guard let image = info[.originalImage] as? UIImage,
              let imageData = image.jpegData(compressionQuality: 0.75) else { return }

        let base64 = imageData.base64EncodedString()
        // Send image back to the web app via JS bridge
        let js = """
        (function() {
            var img = new Image();
            img.onload = function() {
                if (typeof window.generateStoryCanvas === 'function') {
                    window.generateStoryCanvas(img);
                } else if (typeof window.receiveNativePhoto === 'function') {
                    window.receiveNativePhoto(img);
                }
            };
            img.src = 'data:image/jpeg;base64,\(base64)';
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}
