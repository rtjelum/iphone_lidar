import simd

/// A set of colored 3D points in meters.
/// Axes: x right, y up, z toward the phone (the scene is in front of the camera at negative z).
struct PointCloud {
    var positions: [SIMD3<Float>] = []
    /// RGB, each component 0...1.
    var colors: [SIMD3<Float>] = []
    /// Where each point sat in the depth image, so neighbors can be joined into a surface.
    /// `grid[row * gridColumns + column]` is the point's index, or -1 where the camera had no reading.
    var grid: [Int32] = []
    var gridColumns = 0
    /// Changes every time a new cloud is produced, so views know when to rebuild.
    var id: Int = 0

    var count: Int { positions.count }
}
