import Foundation

/// What Google Takeout's JSON file next to a photo or video says about it.
public struct TakeoutSidecar: Equatable, Sendable, Codable {
    /// The original file name, as uploaded to Google.
    public var title: String?
    public var takenAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var favorite: Bool

    public init(title: String? = nil, takenAt: Date? = nil, latitude: Double? = nil, longitude: Double? = nil,
                altitude: Double? = nil, favorite: Bool = false) {
        self.title = title
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.favorite = favorite
    }

    public static func parse(_ data: Data) -> TakeoutSidecar? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        // Google writes 0.0 for every coordinate when it has no place, so 0,0 means "unknown", not the Gulf of Guinea.
        let place = [raw.geoData, raw.geoDataExif].compactMap { $0 }.first { $0.latitude != 0 || $0.longitude != 0 }
        let seconds = raw.photoTakenTime?.timestamp.value ?? 0
        return TakeoutSidecar(title: raw.title, takenAt: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil,
                              latitude: place?.latitude, longitude: place?.longitude,
                              altitude: place.flatMap { $0.altitude },
                              favorite: raw.favorited ?? false)
    }

    private struct Raw: Decodable {
        var title: String?
        var photoTakenTime: Time?
        var geoData: Geo?
        var geoDataExif: Geo?
        var favorited: Bool?
    }

    struct Time: Decodable {
        var timestamp: Seconds
    }

    private struct Geo: Decodable {
        var latitude: Double
        var longitude: Double
        var altitude: Double?
    }

    /// Google writes the timestamp as a string; accept a number too.
    struct Seconds: Decodable {
        var value: TimeInterval

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else {
                value = TimeInterval(try container.decode(String.self)) ?? 0
            }
        }
    }
}

/// The `metadata.json` in a Google Photos album folder.
public struct TakeoutAlbumMetadata: Equatable, Sendable {
    public var title: String

    public static func parse(_ data: Data) -> TakeoutAlbumMetadata? {
        struct Raw: Decodable { var title: String? }
        guard let title = (try? JSONDecoder().decode(Raw.self, from: data))?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return TakeoutAlbumMetadata(title: title)
    }
}
