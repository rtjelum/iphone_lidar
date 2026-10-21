import AVFoundation

enum CameraError: LocalizedError {
    case noTrueDepth
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noTrueDepth: "This device has no TrueDepth camera. It needs a physical iPhone with Face ID."
        case .setupFailed(let what): "Couldn't set up the camera (\(what))."
        }
    }
}

/// Runs the TrueDepth camera and turns each synchronized color + depth frame into a ProcessedFrame.
/// All AVFoundation work happens on background queues; `onFrame` is called on the data queue.
final class DepthCaptureEngine: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    struct Settings {
        var paused = false
        var captureNext = false
        var orientation = ScreenOrientation.portrait
    }

    var onFrame: ((ProcessedFrame, _ isCapture: Bool) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "depth.session")
    private let dataQueue = DispatchQueue(label: "depth.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var fieldOfView: Float = 60

    private let lock = NSLock()
    private var settings = Settings()
    /// True while a frame has been sent to the UI but not shown yet (guarded by `lock`).
    private var waitingForUI = false

    func update(_ change: (inout Settings) -> Void) {
        lock.lock()
        change(&settings)
        lock.unlock()
    }

    func start(completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            do {
                if self.synchronizer == nil { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Smoothing fills holes in the depth map using the color image. Off = raw sensor data.
    func setFiltering(_ enabled: Bool) {
        sessionQueue.async { self.depthOutput.isFilteringEnabled = enabled }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw CameraError.noTrueDepth
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 640x480 video gives the highest-resolution depth map (640x480) on TrueDepth.
        session.sessionPreset = .vga640x480

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.setupFailed("input") }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { throw CameraError.setupFailed("video output") }
        session.addOutput(videoOutput)

        depthOutput.isFilteringEnabled = false  // raw depth by default; matches the "Smooth depth" toggle
        depthOutput.alwaysDiscardsLateDepthData = true
        guard session.canAddOutput(depthOutput) else { throw CameraError.setupFailed("depth output") }
        session.addOutput(depthOutput)

        // Keep both streams unmirrored so color and depth pixels line up.
        for connection in [videoOutput.connection(with: .video), depthOutput.connection(with: .depthData)] {
            guard let connection else { continue }
            connection.isEnabled = true
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        // Pick the largest depth format that delivers depth in meters (Float32).
        let depthFormats = device.activeFormat.supportedDepthDataFormats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        if let best = depthFormats.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) {
            try device.lockForConfiguration()
            device.activeDepthDataFormat = best
            device.unlockForConfiguration()
        }
        fieldOfView = device.activeFormat.videoFieldOfView

        let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        sync.setDelegate(self, queue: dataQueue)
        synchronizer = sync
    }

    // MARK: - Frames

    /// Called by the UI once it has shown a frame, so the next one can be processed.
    func frameShown() {
        lock.lock()
        waitingForUI = false
        lock.unlock()
    }

    private enum FrameMode {
        case skip
        case live
        case capture
    }

    private func nextMode() -> (FrameMode, ScreenOrientation) {
        lock.lock()
        defer { lock.unlock() }
        if settings.captureNext {
            settings.captureNext = false
            settings.paused = true
            waitingForUI = true
            return (.capture, settings.orientation)
        }
        // Skip frames while paused, or while the screen is still busy with the previous one
        // (otherwise frames pile up and the view lags further and further behind).
        if settings.paused || waitingForUI { return (.skip, settings.orientation) }
        waitingForUI = true
        return (.live, settings.orientation)
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let syncedDepth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !syncedDepth.depthDataWasDropped else { return }

        let isCapture: Bool
        let (mode, orientation) = nextMode()
        switch mode {
        case .skip: return
        case .live: isCapture = false
        case .capture: isCapture = true
        }
        // Captures also build a full-resolution point cloud for PLY export.
        let cloudStride: Int? = isCapture ? 1 : nil

        var videoBuffer: CVPixelBuffer?
        if cloudStride != nil,
           let syncedVideo = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
           !syncedVideo.sampleBufferWasDropped {
            videoBuffer = CMSampleBufferGetImageBuffer(syncedVideo.sampleBuffer)
        }

        let depthData = syncedDepth.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let frame = DepthProcessor.process(depthData: depthData,
                                           video: videoBuffer,
                                           cloudStride: cloudStride,
                                           orientation: orientation,
                                           fallbackFOV: fieldOfView)
        onFrame?(frame, isCapture)
    }
}
