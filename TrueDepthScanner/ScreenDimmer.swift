import UIKit

/// Turns the phone's brightness all the way down and back up again.
/// Handy with an external display: the mirrored picture stays at full brightness.
final class ScreenDimmer: ObservableObject {
    @Published var isDimmed = false {
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
    }

    private func apply() {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.screen else { return }
        if isDimmed && isActive {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = 0
        } else if let saved = savedBrightness {
            screen.brightness = saved
            savedBrightness = nil
        }
    }
}
