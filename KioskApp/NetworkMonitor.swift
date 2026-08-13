import Foundation
import SystemConfiguration

// MARK: - NetworkMonitor
// Monitors network reachability using SCNetworkReachability (iOS 2+, no external deps).
// Usage:
//   let monitor = NetworkMonitor(host: "192.168.0.105")
//   monitor.onReachable = { self.reconnect() }
//   monitor.start()
final class NetworkMonitor {

    // Called on main thread when reachability changes
    var onReachable: (() -> Void)?
    var onUnreachable: (() -> Void)?

    private var reachability: SCNetworkReachability?
    private var currentlyReachable = false

    init(host: String) {
        reachability = SCNetworkReachabilityCreateWithName(nil, host)
    }

    // MARK: - Public API

    func start() {
        guard let ref = reachability else { return }

        var context = SCNetworkReachabilityContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        SCNetworkReachabilitySetCallback(ref, { (_, flags, info) in
            guard let info = info else { return }
            let monitor = Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.handleFlags(flags)
        }, &context)

        SCNetworkReachabilityScheduleWithRunLoop(ref, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Check immediately
        var flags = SCNetworkReachabilityFlags()
        if SCNetworkReachabilityGetFlags(ref, &flags) {
            handleFlags(flags)
        }
    }

    func stop() {
        guard let ref = reachability else { return }
        SCNetworkReachabilityUnscheduleFromRunLoop(ref, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    var isReachable: Bool { currentlyReachable }

    // MARK: - Private

    private func handleFlags(_ flags: SCNetworkReachabilityFlags) {
        let reachable = flags.contains(.reachable) && !flags.contains(.connectionRequired)
        guard reachable != currentlyReachable else { return }
        currentlyReachable = reachable
        DispatchQueue.main.async {
            if reachable {
                self.onReachable?()
            } else {
                self.onUnreachable?()
            }
        }
    }
}
