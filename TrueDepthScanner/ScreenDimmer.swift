import AVFoundation
import UIKit

/// Turns the phone's brightness all the way down while a cable display is plugged in, and back up
/// when it's unplugged. The mirrored picture on the display stays at full brightness.
final class ScreenDimmer {
    private var displayConnected = false {
        didSet { apply() }
    }

    /// The brightness before dimming; nil when not dimmed.
    private var savedBrightness: CGFloat?
    private var isActive = true

    init() {
        let center = NotificationCenter.default
        // Give the user their brightness back when they leave the app, and dim again on return.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isActive = false
            self?.apply()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isActive = true
            self?.apply()
        }
        // iOS doesn't tell the app about a cable display directly, but it shows up as an HDMI audio output.
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkDisplay()
        }
        checkDisplay()
    }

    private func checkDisplay() {
        let connected = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .HDMI }
        if connected != displayConnected { displayConnected = connected }
    }

    private func apply() {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.screen else { return }
        if displayConnected && isActive {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = 0
        } else if let saved = savedBrightness {
            screen.brightness = saved
            savedBrightness = nil
        }
    }
}
