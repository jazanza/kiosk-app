import UIKit
import AVFoundation

// MARK: - NativeScreensaverViewController
//
// Full-screen native screensaver that runs OUTSIDE the WKWebView, bypassing
// all iOS 9 autoplay restrictions. It uses AVPlayer for videos and
// UIImageView + CAKeyframeAnimation (Ken Burns) for images.
//
// Architecture:
//   AppDelegate presents this VC first.
//   When user taps → crossfade transition → KioskViewController (WKWebView).
//
// Media source: GET http://<serverIP>:3001/api/screensaver
// Fallback:     Beer images from /api/beer-images or placeholder gradient.

final class NativeScreensaverViewController: UIViewController {

    // Called when user taps to start the kiosk experience
    var onStart: (() -> Void)?

    // Server base URL, set by AppDelegate after IP is configured
    var serverBaseURL: String = "" {
        didSet { fetchMediaList() }
    }

    // MARK: - Private state

    private var mediaItems: [MediaItem] = []
    private var currentIndex = 0
    private var slideTimer: Timer?

    // MARK: - UI

    private let backgroundView = UIView()

    // Two image views for crossfade: one fades in while other fades out
    private let imageViewA = UIImageView()
    private let imageViewB = UIImageView()
    private var activeImageView: UIImageView { currentIndex % 2 == 0 ? imageViewA : imageViewB }
    private var inactiveImageView: UIImageView { currentIndex % 2 == 0 ? imageViewB : imageViewA }

    // AVPlayer layer for videos
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var playerObserver: Any?

    // Overlay UI
    private let gradientLayer = CAGradientLayer()
    private let brandLabel = UILabel()
    private let tapLabel = UILabel()
    private let metaLabel = UILabel()       // selfie name / promo text
    private let loadingIndicator = UIActivityIndicatorView(activityIndicatorStyle: .whiteLarge)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupTapGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !serverBaseURL.isEmpty {
            fetchMediaList()
        } else {
            showPlaceholderAnimation()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopSlideshow()
    }

    override var prefersStatusBarHidden: Bool { return true }

    // MARK: - UI Setup

    private func setupUI() {
        // Background
        backgroundView.frame = view.bounds
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundView.backgroundColor = .black
        view.addSubview(backgroundView)

        // Image views (stacked, crossfade between them)
        for iv in [imageViewA, imageViewB] {
            iv.frame = view.bounds
            iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.alpha = 0
            backgroundView.addSubview(iv)
        }

        // Gradient overlay (top and bottom vignette)
        gradientLayer.frame = view.bounds
        gradientLayer.colors = [
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.70).cgColor
        ]
        gradientLayer.locations = [0.0, 0.25, 0.65, 1.0]
        view.layer.addSublayer(gradientLayer)

        // Brand label (top center)
        brandLabel.text = "🍺 CHIN CHIN"
        brandLabel.font = UIFont(name: "AvenirNext-Heavy", size: 16) ?? UIFont.boldSystemFont(ofSize: 16)
        brandLabel.textColor = UIColor(red: 0.8, green: 1.0, blue: 0.0, alpha: 1.0) // brand neon
        brandLabel.textAlignment = .center
        brandLabel.alpha = 0.9
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(brandLabel)

        // Selfie/promo meta label (bottom, above tap label)
        metaLabel.font = UIFont(name: "AvenirNext-Bold", size: 13) ?? UIFont.boldSystemFont(ofSize: 13)
        metaLabel.textColor = .white
        metaLabel.textAlignment = .center
        metaLabel.alpha = 0
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metaLabel)

        // "TOCA PARA EMPEZAR" pulsing label (bottom)
        tapLabel.text = "TOCA PARA EMPEZAR"
        tapLabel.font = UIFont(name: "AvenirNext-Heavy", size: 11) ?? UIFont.boldSystemFont(ofSize: 11)
        tapLabel.textColor = UIColor(red: 0.8, green: 1.0, blue: 0.0, alpha: 1.0)
        tapLabel.textAlignment = .center
        tapLabel.alpha = 1.0
        tapLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tapLabel)

        // Loading indicator
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingIndicator)

        // Layout
        NSLayoutConstraint.activate([
            brandLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            brandLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            tapLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),
            tapLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            metaLabel.bottomAnchor.constraint(equalTo: tapLabel.topAnchor, constant: -12),
            metaLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            metaLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        startPulseAnimation()
    }

    private func setupTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)
    }

    // MARK: - Pulse animation for "TOCA" label

    private func startPulseAnimation() {
        UIView.animate(withDuration: 1.8,
                       delay: 0,
                       options: [.repeat, .autoreverse, .curveEaseInOut],
                       animations: {
            self.tapLabel.alpha = 0.2
        })
    }

    // MARK: - Media fetching

    private func fetchMediaList() {
        guard !serverBaseURL.isEmpty,
              let url = URL(string: "\(serverBaseURL)/api/screensaver") else {
            showPlaceholderAnimation()
            return
        }

        loadingIndicator.startAnimating()

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loadingIndicator.stopAnimating()

                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    self.mediaItems = json.compactMap { MediaItem(dict: $0, baseURL: self.serverBaseURL) }
                }

                if self.mediaItems.isEmpty {
                    self.showPlaceholderAnimation()
                } else {
                    self.startSlideshow()
                }
            }
        }.resume()
    }

    // MARK: - Slideshow

    private func startSlideshow() {
        currentIndex = 0
        showCurrentSlide()
    }

    private func stopSlideshow() {
        slideTimer?.invalidate()
        slideTimer = nil
        player?.pause()
        playerObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    private func showCurrentSlide() {
        guard !mediaItems.isEmpty else { return }
        let item = mediaItems[currentIndex % mediaItems.count]

        switch item.type {
        case .video:
            showVideo(item)
        case .image, .selfie:
            showImage(item)
        }

        // Update meta label for selfies
        if item.type == .selfie, let name = item.leadName {
            showMetaLabel(text: "📸 \(name)")
        } else {
            hideMetaLabel()
        }
    }

    // MARK: - Image slide with Ken Burns

    private func showImage(_ item: MediaItem) {
        guard let url = URL(string: item.url) else {
            advanceSlide(after: 8)
            return
        }

        // Stop any running video
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { self?.advanceSlide(after: 8) }
                return
            }
            DispatchQueue.main.async {
                self.crossfadeToImage(image)
                self.applyKenBurns(to: self.activeImageView)
                self.advanceSlide(after: 8)
            }
        }.resume()
    }

    private func crossfadeToImage(_ image: UIImage) {
        activeImageView.image = image
        activeImageView.transform = .identity

        UIView.animate(withDuration: 1.2, animations: {
            self.activeImageView.alpha = 1.0
            self.inactiveImageView.alpha = 0.0
        })
    }

    // Ken Burns: slow pan + zoom using CABasicAnimation (CoreAnimation, rock solid on iOS 9)
    private func applyKenBurns(to imageView: UIImageView) {
        imageView.layer.removeAllAnimations()

        // Randomly pick one of 4 Ken Burns variants
        let variants: [(CATransform3D, CATransform3D)] = [
            (CATransform3DMakeScale(1.0, 1.0, 1.0), CATransform3DScale(CATransform3DMakeTranslation(-15, -8, 0), 1.08, 1.08, 1)),
            (CATransform3DMakeScale(1.08, 1.08, 1.0), CATransform3DScale(CATransform3DMakeTranslation(15, 10, 0), 1.0, 1.0, 1)),
            (CATransform3DScale(CATransform3DIdentity, 1.0, 1.0, 1.0), CATransform3DScale(CATransform3DMakeTranslation(0, -12, 0), 1.06, 1.06, 1)),
            (CATransform3DScale(CATransform3DIdentity, 1.05, 1.05, 1.0), CATransform3DScale(CATransform3DMakeTranslation(10, 5, 0), 1.0, 1.0, 1)),
        ]
        let chosen = variants[Int.random(in: 0..<variants.count)]

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: chosen.0)
        anim.toValue = NSValue(caTransform3D: chosen.1)
        anim.duration = 9.0
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer.add(anim, forKey: "kenBurns")
    }

    // MARK: - Video slide with AVPlayer

    private func showVideo(_ item: MediaItem) {
        guard let url = URL(string: item.url) else {
            advanceSlide(after: 8)
            return
        }

        // Remove previous
        playerObserver.map { NotificationCenter.default.removeObserver($0) }
        playerLayer?.removeFromSuperlayer()

        let avItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: avItem)
        player?.isMuted = true

        let layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspectFill
        backgroundView.layer.addSublayer(layer)
        playerLayer = layer

        // Hide image views while video plays
        UIView.animate(withDuration: 0.5) {
            self.imageViewA.alpha = 0
            self.imageViewB.alpha = 0
        }

        player?.play()

        // Advance when video ends
        playerObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avItem,
            queue: .main
        ) { [weak self] _ in
            self?.advance()
        }

        // Safety timeout: if video takes too long, skip
        advanceSlide(after: 60)
    }

    // MARK: - Slide advancement

    private func advanceSlide(after seconds: TimeInterval) {
        slideTimer?.invalidate()
        slideTimer = Timer.scheduledTimer(timeInterval: seconds, target: self, selector: #selector(advance), userInfo: nil, repeats: false)
    }

    @objc private func advance() {
        slideTimer?.invalidate()
        currentIndex += 1
        if currentIndex >= mediaItems.count { currentIndex = 0 }
        showCurrentSlide()
    }

    // MARK: - Placeholder (no server / no media)

    private func showPlaceholderAnimation() {
        // Animated gradient as fallback — works 100% offline
        let colors: [[CGColor]] = [
            [UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1).cgColor,
             UIColor(red: 0.12, green: 0.10, blue: 0.02, alpha: 1).cgColor],
            [UIColor(red: 0.02, green: 0.08, blue: 0.02, alpha: 1).cgColor,
             UIColor(red: 0.15, green: 0.12, blue: 0.0, alpha: 1).cgColor],
        ]
        let bg = CAGradientLayer()
        bg.frame = view.bounds
        bg.colors = colors[0]
        bg.startPoint = CGPoint(x: 0, y: 0)
        bg.endPoint = CGPoint(x: 1, y: 1)
        backgroundView.layer.insertSublayer(bg, at: 0)

        let colorAnim = CABasicAnimation(keyPath: "colors")
        colorAnim.toValue = colors[1]
        colorAnim.duration = 4.0
        colorAnim.autoreverses = true
        colorAnim.repeatCount = .infinity
        bg.add(colorAnim, forKey: "colorCycle")
    }

    // MARK: - Meta label

    private func showMetaLabel(text: String) {
        metaLabel.text = text
        UIView.animate(withDuration: 0.5) { self.metaLabel.alpha = 1 }
    }

    private func hideMetaLabel() {
        UIView.animate(withDuration: 0.3) { self.metaLabel.alpha = 0 }
    }

    // MARK: - Tap handler

    @objc private func handleTap() {
        stopSlideshow()
        UIView.animate(withDuration: 0.4, animations: {
            self.view.alpha = 0
        }) { _ in
            self.onStart?()
        }
    }
}

// MARK: - MediaItem model

private struct MediaItem {
    enum MediaType { case image, video, selfie }
    let url: String
    let type: MediaType
    let leadName: String?

    init?(dict: [String: Any], baseURL: String) {
        guard let rawURL = dict["url"] as? String else { return nil }
        let typeStr = dict["type"] as? String ?? "image"
        self.leadName = dict["leadName"] as? String

        switch typeStr {
        case "video":  self.type = .video
        case "selfie": self.type = .selfie
        default:       self.type = .image
        }

        // Build absolute URL
        if rawURL.hasPrefix("http") {
            self.url = rawURL
        } else {
            self.url = "\(baseURL)\(rawURL)"
        }
    }
}
