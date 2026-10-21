import AVFoundation
import SwiftUI

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

final class DepthViewModel: ObservableObject {
    enum Status: Equatable {
        case starting, running, denied
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var lines: DepthLines?
    /// Lines mode: height of a line at 20 cm or closer, in line spacings.
    @Published var relief: Double = 15
    /// Lines mode: line width as a fraction of the spacing between lines.
    @Published var lineWidth: Double = 0.25
    /// Slowly-updated typical rise of the top and bottom lines (see DepthLinesView).
    private(set) var topRise: Double = 0
    private(set) var bottomRise: Double = 0
    @Published private(set) var cloud = PointCloud()
    @Published private(set) var isCaptured = false
    @Published private(set) var isExporting = false
    @Published var exportFile: ExportFile?
    @Published var errorMessage: String?

    /// Show the picture mirrored, like a selfie (only affects the display, not exports).
    @Published var mirrored = true

    @Published var smoothing = false {
        didSet { engine.setFiltering(smoothing) }
    }

    private let engine = DepthCaptureEngine()
    private var cloudCounter = 0
    private var orientationObservation: NSKeyValueObservation?

    init() {
        engine.onFrame = { [weak self] frame, isCapture in
            DispatchQueue.main.async { self?.apply(frame, isCapture: isCapture) }
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.startEngine() } else { self.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    /// Keeps the depth image upright as the screen rotates.
    func watchOrientation() {
        guard orientationObservation == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        orientationObservation = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
            let orientation: ScreenOrientation
            switch scene.effectiveGeometry.interfaceOrientation {
            case .landscapeLeft: orientation = .landscapeLeft
            case .landscapeRight: orientation = .landscapeRight
            default: orientation = .portrait
            }
            self?.engine.update { $0.orientation = orientation }
        }
    }

    /// Grabs the next frame at full resolution and freezes the view on it.
    func capture() {
        engine.update { $0.captureNext = true }
    }

    func resume() {
        isCaptured = false
        engine.update { $0.paused = false }
    }

    func export() {
        let cloud = self.cloud
        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PLYExporter.write(cloud) }
            DispatchQueue.main.async {
                self.isExporting = false
                switch result {
                case .success(let url): self.exportFile = ExportFile(url: url)
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startEngine() {
        engine.start { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.status = .failed(error.localizedDescription)
                } else {
                    self?.status = .running
                }
            }
        }
    }

    /// Median height of the given rows, ignoring gaps. Nil if they have no readings.
    private static func medianNearness(_ lines: DepthLines, rows: Range<Int>) -> Double? {
        var values: [Float] = []
        for r in rows {
            for c in 0..<lines.cols {
                let v = lines.nearness[r * lines.cols + c]
                if !v.isNaN { values.append(v) }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return Double(values[values.count / 2])
    }

    private func apply(_ frame: ProcessedFrame, isCapture: Bool) {
        if let newLines = frame.lines {
            // Ease toward the new values so the picture doesn't jump.
            if let t = Self.medianNearness(newLines, rows: 0..<3) { topRise += (t - topRise) * 0.1 }
            if let b = Self.medianNearness(newLines, rows: (newLines.rows - 3)..<newLines.rows) {
                bottomRise += (b - bottomRise) * 0.1
            }
            lines = newLines
        }
        if var newCloud = frame.cloud {
            cloudCounter += 1
            newCloud.id = cloudCounter
            cloud = newCloud
        }
        if isCapture { isCaptured = true }
        engine.frameShown()
    }
}
