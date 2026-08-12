import UIKit
import WebKit

class ViewController: UIViewController, WKScriptMessageHandler, UIImagePickerControllerDelegate, UINavigationControllerDelegate, WKNavigationDelegate {
    var webView: WKWebView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(self, name: "cameraHandler")
        
        // Inject JS to override the button
        let js = """
        setInterval(function() {
            var labelBtn = document.querySelector('.camera-label-btn');
            if (labelBtn && !labelBtn.dataset.hijacked) {
                labelBtn.dataset.hijacked = 'true';
                labelBtn.innerHTML = '📷 TOMAR SELFIE'; 
                labelBtn.onclick = function(e) {
                    e.preventDefault();
                    window.webkit.messageHandlers.cameraHandler.postMessage('openFrontCamera');
                };
            }
        }, 1000);
        """
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        contentController.addUserScript(script)
        config.userContentController = contentController
        
        // Enable inline video
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
        view.addSubview(webView)
        
        // Settings Button (invisible, top right)
        let settingsBtn = UIButton(frame: CGRect(x: view.bounds.width - 100, y: 0, width: 100, height: 100))
        settingsBtn.backgroundColor = .clear
        settingsBtn.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(showSettings))
        longPress.minimumPressDuration = 3.0
        settingsBtn.addGestureRecognizer(longPress)
        view.addSubview(settingsBtn)
        
        loadKiosk()
    }
    
    func loadKiosk() {
        let ip = UserDefaults.standard.string(forKey: "kioskIP") ?? "192.168.0.112"
        if let url = URL(string: "http://\(ip):3001/kiosk-legacy") {
            webView.load(URLRequest(url: url))
        }
    }
    
    @objc func showSettings() {
        let ip = UserDefaults.standard.string(forKey: "kioskIP") ?? "192.168.0.112"
        let alert = UIAlertController(title: "Configuración IP", message: "Ingresa la IP del servidor Node.js", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = ip
            tf.keyboardType = .decimalPad
        }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Guardar", style: .default, handler: { _ in
            if let newIP = alert.textFields?.first?.text {
                UserDefaults.standard.set(newIP, forKey: "kioskIP")
                self.loadKiosk()
            }
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showSettings()
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "cameraHandler", let msg = message.body as? String, msg == "openFrontCamera" {
            DispatchQueue.main.async {
                self.openFrontCamera()
            }
        }
    }
    
    func openFrontCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            if UIImagePickerController.isCameraDeviceAvailable(.front) {
                picker.cameraDevice = .front
            }
            picker.delegate = self
            picker.showsCameraControls = true
            present(picker, animated: true, completion: nil)
        } else {
            print("Cámara no disponible")
        }
    }
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true, completion: nil)
        if let image = info[.originalImage] as? UIImage,
           let imageData = image.jpegData(compressionQuality: 0.7) {
            let base64 = imageData.base64EncodedString()
            let js = "var img = new Image(); img.onload = function() { window.generateStoryCanvas(img); }; img.src = 'data:image/jpeg;base64,\(base64)';"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
}
