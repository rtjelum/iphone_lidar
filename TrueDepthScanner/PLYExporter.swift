import Foundation

/// Writes a point cloud as a binary PLY file (opens in Blender, MeshLab, CloudCompare, ...).
enum PLYExporter {
    static func write(_ cloud: PointCloud) throws -> URL {
        let header = """
        ply
        format binary_little_endian 1.0
        comment Captured with the TrueDepth camera. Units: meters.
        element vertex \(cloud.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + cloud.count * 15)

        for (p, c) in zip(cloud.positions, cloud.colors) {
            for value in [p.x, p.y, p.z] {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(byte(c.x))
            data.append(byte(c.y))
            data.append(byte(c.z))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrueDepth-\(formatter.string(from: Date())).ply")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func byte(_ v: Float) -> UInt8 {
        UInt8((max(0, min(1, v)) * 255).rounded())
    }
}
