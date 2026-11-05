import Foundation

/// Object coordinate space used by the Renderer: x ∈ [-1, 1] (left→right),
/// y ∈ [-1, 1] (front→back), z ∈ [0, 1] (floor→ceiling).
public struct SpatialPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let center = SpatialPoint(x: 0, y: 0, z: 0)

    public var clamped: SpatialPoint {
        SpatialPoint(
            x: min(max(x, -1), 1),
            y: min(max(y, -1), 1),
            z: min(max(z, 0), 1)
        )
    }

    public func interpolated(to other: SpatialPoint, t: Double) -> SpatialPoint {
        SpatialPoint(
            x: x + (other.x - x) * t,
            y: y + (other.y - y) * t,
            z: z + (other.z - z) * t
        )
    }

    /// Max height in the object field is rendered at this elevation.
    public static let ceilingElevation = 60.0

    /// Spherical representation. 0° azimuth is front, positive is right.
    public var spherical: SphericalPoint {
        let p = clamped
        let azimuth = atan2(p.x, -p.y) * 180.0 / .pi
        let elevation = asin(min(max(p.z, 0), 1)) * 180.0 / .pi * (SpatialPoint.ceilingElevation / 90.0)
        let radius = min(1.0, (p.x * p.x + p.y * p.y).squareRoot())
        return SphericalPoint(azimuth: azimuth, elevation: elevation, radius: radius)
    }

    public static func fromSpherical(azimuth: Double, elevation: Double, radius: Double) -> SpatialPoint {
        let az = azimuth * .pi / 180.0
        let el = elevation * .pi / 180.0 * (90.0 / ceilingElevation)
        let horizontal = cos(el)
        return SpatialPoint(
            x: sin(az) * horizontal * radius,
            y: -cos(az) * horizontal * radius,
            z: sin(el) * 1.0
        ).clamped
    }

    /// Unit vector in a right-handed room space where +y is up.
    public var unitVector: (x: Double, y: Double, z: Double) {
        let s = spherical
        let az = s.azimuth * .pi / 180
        let el = s.elevation * .pi / 180
        return (sin(az) * cos(el), sin(el), cos(az) * cos(el))
    }
}

public struct SphericalPoint: Codable, Sendable, Hashable {
    public var azimuth: Double
    public var elevation: Double
    public var radius: Double

    public init(azimuth: Double, elevation: Double, radius: Double) {
        self.azimuth = azimuth
        self.elevation = elevation
        self.radius = radius
    }

    public var unitVector: (x: Double, y: Double, z: Double) {
        let az = azimuth * .pi / 180
        let el = elevation * .pi / 180
        return (sin(az) * cos(el), sin(el), cos(az) * cos(el))
    }

    public func angularDistance(to other: SphericalPoint) -> Double {
        let a = unitVector
        let b = other.unitVector
        let dot = min(max(a.x * b.x + a.y * b.y + a.z * b.z, -1), 1)
        return acos(dot) * 180 / .pi
    }
}

public enum DistanceModel: String, Codable, Sendable, CaseIterable {
    case off, near, mid, far
    public var label: String {
        switch self {
        case .off: "Off"; case .near: "Near"; case .mid: "Mid"; case .far: "Far"
        }
    }
    /// Binaural distance attenuation applied on top of the room radius.
    public var attenuationDB: Double {
        switch self {
        case .off: 0; case .near: -1.5; case .mid: -3.0; case .far: -6.0
        }
    }
    /// Level sent to the binaural virtual room. `.off` bypasses binaural processing
    /// entirely (plain stereo pan), matching the documented render-mode semantics.
    public var roomSendDB: Double {
        switch self {
        case .off: -.infinity; case .near: -17; case .mid: -11; case .far: -6
        }
    }
}

/// Keyframed object trajectory with a linear interpolation segment model.
public struct ObjectKeyframe: Codable, Sendable, Hashable {
    public var time: Double
    public var position: SpatialPoint
    public var size: Double

    public init(time: Double, position: SpatialPoint, size: Double) {
        self.time = time
        self.position = position
        self.size = size
    }
}
