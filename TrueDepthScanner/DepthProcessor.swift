import AVFoundation
import CoreGraphics
import simd

/// Raw depth samples for the lines view, already turned upright (portrait, mirrored like a selfie).
struct DepthLines {
    let rows: Int
    let cols: Int
    /// Row-major height per sample: 20 cm / depth, capped at 1.
    /// 20 cm or closer = 1, 40 cm = 0.5, 1 m = 0.2, far away -> 0. NaN = no sensor reading.
    let nearness: [Float]
    /// Width / height of the upright image.
    let aspect: CGFloat
}

struct ProcessedFrame {
    var lines: DepthLines?
    /// Only built for captures (used for PLY export).
    var cloud: PointCloud?
}


struct CameraIntrinsics {
    var fx: Float, fy: Float, cx: Float, cy: Float
}

/// Read-only view of a Float32 depth buffer (values in meters).
struct DepthGrid {
    let base: UnsafeRawPointer
    let width: Int
    let height: Int
    let rowBytes: Int

    @inline(__always) func row(_ y: Int) -> UnsafePointer<Float32> {
        base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
    }
}

enum DepthProcessor {
    /// Anything closer than this is treated as invalid.
    static let minDepth: Float = 0.1

    /// `depthData` must already be converted to kCVPixelFormatType_DepthFloat32.
    /// Pass `cloudStride` to also build a point cloud (1 = every pixel, 2 = every other pixel, ...).
    static func process(depthData: AVDepthData,
                        video: CVPixelBuffer?,
                        cloudStride: Int?,
                        fallbackFOV: Float) -> ProcessedFrame {
        let depthMap = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return ProcessedFrame() }

        let depth = DepthGrid(base: UnsafeRawPointer(base),
                              width: CVPixelBufferGetWidth(depthMap),
                              height: CVPixelBufferGetHeight(depthMap),
                              rowBytes: CVPixelBufferGetBytesPerRow(depthMap))

        var frame = ProcessedFrame()
        frame.lines = makeLines(depth)
        if let step = cloudStride {
            let k = intrinsics(for: depthData, width: depth.width, height: depth.height, fallbackFOV: fallbackFOV)
            frame.cloud = makeCloud(depth, intrinsics: k, video: video, step: step)
        }
        return frame
    }


    // MARK: - Lines

    /// Depth that gets full line height.
    static let linesReferenceDepth: Float = 0.2

    /// Picks one raw sensor pixel per point (no averaging), on a grid of horizontal lines.
    /// Height = 20 cm / depth, so the full range is shown with no cutoff.
    static func makeLines(_ depth: DepthGrid, rows: Int = 100, cols: Int = 160) -> DepthLines {
        // The upright image is the buffer transposed (like a UIImage with .leftMirrored orientation):
        // upright x = buffer row, upright y = buffer column.
        let uprightWidth = depth.height
        let uprightHeight = depth.width
        var nearness = [Float](repeating: .nan, count: rows * cols)
        for r in 0..<rows {
            let bufferCol = min(depth.width - 1, Int((Float(r) + 0.5) / Float(rows) * Float(uprightHeight)))
            for c in 0..<cols {
                let bufferRow = min(depth.height - 1, Int(Float(c) / Float(cols - 1) * Float(uprightWidth - 1)))
                let d = depth.row(bufferRow)[bufferCol]
                guard d.isFinite, d > minDepth else { continue }
                nearness[r * cols + c] = min(1, linesReferenceDepth / d)
            }
        }
        return DepthLines(rows: rows, cols: cols, nearness: nearness,
                          aspect: CGFloat(uprightWidth) / CGFloat(uprightHeight))
    }

    // MARK: - Point cloud

    static func intrinsics(for depthData: AVDepthData, width: Int, height: Int, fallbackFOV: Float) -> CameraIntrinsics {
        if let calibration = depthData.cameraCalibrationData {
            // The matrix is given for a larger reference resolution; scale it down to the depth map.
            let m = calibration.intrinsicMatrix
            let ref = calibration.intrinsicMatrixReferenceDimensions
            let sx = Float(width) / Float(ref.width)
            let sy = Float(height) / Float(ref.height)
            return CameraIntrinsics(fx: m.columns.0.x * sx, fy: m.columns.1.y * sy,
                                    cx: m.columns.2.x * sx, cy: m.columns.2.y * sy)
        }
        let f = Float(width) / 2 / tan(fallbackFOV * .pi / 360)
        return CameraIntrinsics(fx: f, fy: f, cx: Float(width) / 2, cy: Float(height) / 2)
    }

    static func makeCloud(_ depth: DepthGrid,
                          intrinsics k: CameraIntrinsics,
                          video: CVPixelBuffer?,
                          step: Int) -> PointCloud {
        var cloud = PointCloud()
        let estimate = (depth.width / step) * (depth.height / step)
        cloud.positions.reserveCapacity(estimate)
        cloud.colors.reserveCapacity(estimate)

        if let video { CVPixelBufferLockBaseAddress(video, .readOnly) }
        defer { if let video { CVPixelBufferUnlockBaseAddress(video, .readOnly) } }

        var colorAt: (Int, Int) -> SIMD3<Float> = { _, _ in SIMD3(0.8, 0.8, 0.8) }
        if let video,
           CVPixelBufferGetPixelFormatType(video) == kCVPixelFormatType_32BGRA,
           let vBase = CVPixelBufferGetBaseAddress(video) {
            let vw = CVPixelBufferGetWidth(video)
            let vh = CVPixelBufferGetHeight(video)
            let vRow = CVPixelBufferGetBytesPerRow(video)
            let sx = Float(vw) / Float(depth.width)
            let sy = Float(vh) / Float(depth.height)
            colorAt = { x, y in
                let px = min(Int(Float(x) * sx), vw - 1)
                let py = min(Int(Float(y) * sy), vh - 1)
                let p = vBase.advanced(by: py * vRow + px * 4).assumingMemoryBound(to: UInt8.self)
                return SIMD3(Float(p[2]), Float(p[1]), Float(p[0])) / 255  // BGRA -> RGB
            }
        }

        for y in stride(from: 0, to: depth.height, by: step) {
            let row = depth.row(y)
            for x in stride(from: 0, to: depth.width, by: step) {
                let d = row[x]
                guard d.isFinite, d > minDepth else { continue }
                // Camera space: X along buffer columns, Y along buffer rows, Z forward.
                let camX = (Float(x) - k.cx) * d / k.fx
                let camY = (Float(y) - k.cy) * d / k.fy
                // The front camera's buffer is sideways relative to a portrait phone.
                // Rotate it upright: x right, y up, z toward the viewer.
                cloud.positions.append(SIMD3(-camY, -camX, -d))
                cloud.colors.append(colorAt(x, y))
            }
        }
        return cloud
    }
}
