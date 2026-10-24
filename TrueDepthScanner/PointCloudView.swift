import SceneKit
import SwiftUI

/// Shows a captured point cloud in 3D as a solid surface, built from the same points the PLY export writes.
/// The picture sits a bit above the middle of the screen, seen from the phone's angle.
struct PointCloudView: View {
    let cloud: PointCloud
    var mirrored = false

    /// How far above the middle of the screen the capture is shown, as a fraction of the height.
    static let raise: CGFloat = 0.15
    /// The 3D view is drawn this much taller than the screen, sticking out above it, so its middle
    /// lands `raise` above the screen's middle. Moving the picture this way keeps the camera angle.
    static let heightScale: CGFloat = 1 + 2 * raise
    /// Half of the lens angle across the visible height, in radians (60° in total).
    static let visibleHalfAngle: Float = 30 * .pi / 180

    var body: some View {
        GeometryReader { geo in
            PointCloudSceneView(cloud: cloud, mirrored: mirrored)
                .frame(width: geo.size.width, height: geo.size.height * Self.heightScale)
                .position(x: geo.size.width / 2, y: geo.size.height * (0.5 - Self.raise))
        }
        .clipped()
    }
}

/// The SceneKit view behind PointCloudView.
/// Opens showing the whole capture. Drag to orbit, pinch to zoom in/out, two-finger drag to pan,
/// double-tap to see the whole capture again.
struct PointCloudSceneView: UIViewRepresentable {
    let cloud: PointCloud
    /// Flip left and right, like a selfie (matches the Mirror button).
    var mirrored = false

    final class Coordinator: NSObject {
        var shownID: Int?
        var mirrored: Bool?
        weak var view: SCNView?
        /// The box around the capture (stray points left out), used to fit it on screen.
        var bounds = (min: SIMD3<Float>(-0.1, -0.1, -0.6), max: SIMD3<Float>(0.1, 0.1, -0.4))
        /// Camera distance at which the whole capture fits on screen.
        private var fitDistance: Float = 0.5
        private var startDistance: Float = 0

        /// Moves the camera in front of the capture, on the line toward where the phone was,
        /// aimed at the middle of the capture.
        func showAll(animated: Bool) {
            guard let view, let camera = view.pointOfView else { return }
            // When mirrored the scene is flipped left-right, so flip the box the same way.
            var low = bounds.min, high = bounds.max
            if mirrored == true { (low.x, high.x) = (-high.x, -low.x) }
            let center = (low + high) / 2
            let half = (high - low) / 2
            // Fit to the visible part of the view (it's drawn taller than the screen, see PointCloudView).
            let size = view.bounds.size
            let visibleHeight = size.height / PointCloudView.heightScale
            let aspect = size.width > 0 && size.height > 0 ? Float(size.width / visibleHeight) : 0.6
            let vertical = PointCloudView.visibleHalfAngle
            let horizontal = atan(tan(vertical) * aspect)
            // The 0.5 starts closer than an exact fit: the edges are mostly stray points.
            fitDistance = (max(half.y / tan(vertical), half.x / tan(horizontal)) * 1.15 + half.z) * 0.5
            camera.camera?.zFar = Double(fitDistance * 8 + half.z * 2)

            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.35 : 0
            // Look from the phone's direction (the phone was at the origin), so the angle
            // matches what the camera saw, just closer.
            let length = simd_length(center)
            let towardPhone = length > 0 ? -center / length : SIMD3<Float>(0, 0, 1)
            camera.simdWorldPosition = center + towardPhone * fitDistance
            camera.simdLook(at: center, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
            SCNTransaction.commit()
            view.defaultCameraController.target = SCNVector3(center)
        }

        /// Pinch moves the camera toward (spread) or away from (pinch) the orbit center.
        @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
            guard let view, let camera = view.pointOfView else { return }
            let target = simd_float3(view.defaultCameraController.target)
            let offset = camera.simdWorldPosition - target
            let distance = simd_length(offset)
            switch pinch.state {
            case .began:
                startDistance = distance
            case .changed:
                guard distance > 0, pinch.scale > 0 else { return }
                // Zoom out up to 4x past the full view.
                let newDistance = min(fitDistance * 4, max(0.03, startDistance / Float(pinch.scale)))
                camera.simdWorldPosition = target + offset / distance * newDistance
            default:
                break
            }
        }

        @objc func doubleTapped() { showAll(animated: true) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        // Swap SceneKit's own pinch (which changes the lens) for one that moves the camera.
        for recognizer in view.gestureRecognizers ?? [] where recognizer is UIPinchGestureRecognizer {
            view.removeGestureRecognizer(recognizer)
        }
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator,
                                                          action: #selector(Coordinator.pinched)))
        // Double-tap: back to the full view (replacing SceneKit's own double-tap).
        for case let tap as UITapGestureRecognizer in view.gestureRecognizers ?? [] where tap.numberOfTapsRequired == 2 {
            view.removeGestureRecognizer(tap)
        }
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        let newCloud = coordinator.shownID != cloud.id
        guard newCloud || coordinator.mirrored != mirrored else { return }
        if newCloud {
            coordinator.shownID = cloud.id
            view.scene = Self.makeScene(cloud)
            if let camera = view.scene?.rootNode.childNode(withName: "camera", recursively: false) {
                view.pointOfView = camera
            }
            coordinator.bounds = Self.bounds(of: cloud)
        }
        coordinator.mirrored = mirrored
        view.scene?.rootNode.childNode(withName: "surface", recursively: false)?.simdScale =
            SIMD3(mirrored ? -1 : 1, 1, 1)
        coordinator.showAll(animated: !newCloud)
        // On first appearance the view may not have its size yet; fit again once it does.
        if newCloud { DispatchQueue.main.async { coordinator.showAll(animated: false) } }
    }

    private static func makeScene(_ cloud: PointCloud) -> SCNScene {
        let scene = SCNScene()
        guard cloud.count > 0 else { return scene }

        let stride = MemoryLayout<SIMD3<Float>>.stride
        let positions = SCNGeometrySource(
            data: cloud.positions.withUnsafeBufferPointer { Data(buffer: $0) },
            semantic: .vertex, vectorCount: cloud.count, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let colors = SCNGeometrySource(
            data: cloud.colors.withUnsafeBufferPointer { Data(buffer: $0) },
            semantic: .color, vectorCount: cloud.count, usesFloatComponents: true,
            componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)

        let triangles = surfaceTriangles(cloud)
        let element: SCNGeometryElement
        if triangles.isEmpty {
            // No grid to join (shouldn't happen for camera captures): fall back to dots.
            element = SCNGeometryElement(indices: (0..<UInt32(cloud.count)).map { $0 }, primitiveType: .point)
            element.pointSize = 0.002
            element.minimumPointScreenSpaceRadius = 1
            element.maximumPointScreenSpaceRadius = 4
        } else {
            element = SCNGeometryElement(indices: triangles, primitiveType: .triangles)
        }

        let geometry = SCNGeometry(sources: [positions, colors], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant  // show the captured colors as they are
        material.isDoubleSided = true       // so it stays solid when turned around
        geometry.materials = [material]
        let surface = SCNNode(geometry: geometry)
        surface.name = "surface"
        scene.rootNode.addChildNode(surface)

        // Placed by Coordinator.showAll.
        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        // Wider than the visible 60°, since the view is drawn taller than the screen.
        camera.camera?.fieldOfView = Double(2 * atan(tan(PointCloudView.visibleHalfAngle) * Float(PointCloudView.heightScale))) * 180 / .pi
        scene.rootNode.addChildNode(camera)
        return scene
    }

    /// Joins each point to its right and lower neighbors in the depth image, two triangles per square.
    /// A triangle is skipped if its corners are far apart in depth: that's an edge
    /// (say, a head in front of a wall), not a surface, and joining it would draw a curtain.
    private static func surfaceTriangles(_ cloud: PointCloud) -> [UInt32] {
        let cols = cloud.gridColumns
        guard cols > 1, cloud.grid.count >= cols * 2 else { return [] }
        let rows = cloud.grid.count / cols
        let grid = cloud.grid
        let z = cloud.positions.map { -$0.z }  // distance from the camera
        var triangles: [UInt32] = []
        triangles.reserveCapacity(cloud.count * 6)

        func add(_ a: Int32, _ b: Int32, _ c: Int32) {
            guard a >= 0, b >= 0, c >= 0 else { return }
            let za = z[Int(a)], zb = z[Int(b)], zc = z[Int(c)]
            let near = min(za, zb, zc), far = max(za, zb, zc)
            // Allow 4% of the distance (2 cm at 50 cm), plus a little for sensor noise.
            guard far - near < 0.005 + near * 0.04 else { return }
            triangles.append(UInt32(a)); triangles.append(UInt32(b)); triangles.append(UInt32(c))
        }

        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let topLeft = grid[r * cols + c], topRight = grid[r * cols + c + 1]
                let bottomLeft = grid[(r + 1) * cols + c], bottomRight = grid[(r + 1) * cols + c + 1]
                add(topLeft, bottomLeft, topRight)
                add(topRight, bottomLeft, bottomRight)
            }
        }
        return triangles
    }

    /// The box around the capture, leaving out the 1% most extreme points on each side
    /// so a few stray readings don't make it tiny on screen.
    private static func bounds(of cloud: PointCloud) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard cloud.count > 0 else { return (SIMD3(-0.1, -0.1, -0.6), SIMD3(0.1, 0.1, -0.4)) }
        func range(_ values: [Float]) -> (Float, Float) {
            let sorted = values.sorted()
            let cut = sorted.count / 100
            return (sorted[cut], sorted[sorted.count - 1 - cut])
        }
        let x = range(cloud.positions.map(\.x))
        let y = range(cloud.positions.map(\.y))
        let z = range(cloud.positions.map(\.z))
        return (SIMD3(x.0, y.0, z.0), SIMD3(x.1, y.1, z.1))
    }
}
