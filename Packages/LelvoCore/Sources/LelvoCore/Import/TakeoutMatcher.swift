import Foundation

public enum TakeoutFileKind: String, Sendable, Codable {
    case photo, video, sidecar, albumMetadata, other
}

/// Google Takeout's file naming: which files are photos and videos, and which JSON file belongs to which photo.
/// Google changed the sidecar names over the years and cuts long ones, so a photo has many possible sidecar names.
public enum TakeoutMatcher {
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "avif", "tif", "tiff",
                                               "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw"]
    /// `mp` is the video half of a Pixel motion photo.
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2", "mkv", "avi", "wmv", "mts", "m2ts",
                                               "webm", "mpg", "mpeg", "mp"]
    /// An album folder's `metadata.json`, localised like the rest of the export.
    static let albumMetadataNames: Set<String> = ["metadata.json", "metadaten.json", "métadonnées.json", "metadatos.json",
                                                  "metadati.json", "metadados.json", "metagegevens.json", "metadane.json"]
    /// What Google appends to the edited copy of a photo, per language.
    static let editedSuffixes = ["-edited", "-bearbeitet", "-modifié", "-editado", "-modificato", "-bewerkt",
                                 "-edytowane", "-editat", "-ha editado", "-編集済み"]

    /// Google cuts a sidecar's file name to this many characters, `.json` included.
    static let maxSidecarName = 51
    static let supplemental = ".supplemental-metadata"

    public static func kind(ofPath path: String) -> TakeoutFileKind {
        let name = fileName(path)
        let ext = (name as NSString).pathExtension.lowercased()
        if photoExtensions.contains(ext) { return .photo }
        if videoExtensions.contains(ext) { return .video }
        if ext == "json" {
            return albumMetadataNames.contains(name.precomposedStringWithCanonicalMapping.lowercased()) ? .albumMetadata : .sidecar
        }
        return .other
    }

    /// Every name Google may have given this photo's JSON file, in the same folder, most likely first.
    public static func sidecarCandidates(forMediaPath path: String) -> [String] {
        let (dir, name) = split(path)
        var bases = [name]
        if let original = originalPath(ofEditedPath: path) { bases.append(fileName(original)) }
        let stemLimit = maxSidecarName - ".json".count
        var out: [String] = []
        var seen = Set<String>()
        func add(_ candidate: String) {
            if seen.insert(candidate).inserted { out.append(dir + candidate) }
        }
        for base in bases {
            let (plain, number) = splitDuplicate(base)
            // `.supplemental-metadata` (2024 onwards), cut at any length, then the older plain `.json`.
            let stems = (1...supplemental.count).reversed().map { plain + supplemental.prefix($0) } + [plain]
            for stem in stems {
                if let number {
                    add(stem + number + ".json")
                    add(String(stem.prefix(stemLimit - number.count)) + number + ".json")
                    add(String(stem.prefix(stemLimit)) + number + ".json")
                } else {
                    add(stem + ".json")
                    add(String(stem.prefix(stemLimit)) + ".json")
                }
            }
            if number != nil {
                // Some exports keep the number where it was: `IMG_1234(1).jpg.json`.
                add(base + supplemental + ".json")
                add(String((base + supplemental).prefix(stemLimit)) + ".json")
                add(base + ".json")
                add(String(base.prefix(stemLimit)) + ".json")
            }
        }
        return out
    }

    /// The original's path for an edited copy (`IMG_1234-edited.jpg` → `IMG_1234.jpg`), nil for anything else.
    public static func originalPath(ofEditedPath path: String) -> String? {
        let (dir, name) = split(path)
        let ext = (name as NSString).pathExtension
        var stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var number = ""
        if let match = stem.range(of: #"\(\d+\)$"#, options: .regularExpression) {
            number = String(stem[match])
            stem.removeSubrange(match)
        }
        let lower = stem.lowercased()
        guard let suffix = editedSuffixes.first(where: { lower.hasSuffix($0) }) else { return nil }
        let original = String(stem.dropLast(suffix.count))
        guard !original.isEmpty else { return nil }
        return dir + original + number + (ext.isEmpty ? "" : "." + ext)
    }

    /// The key used to compare paths: Unicode NFC (zips made on a Mac can use decomposed names) and lowercased.
    public static func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func fileName(_ path: String) -> String {
        split(path).name
    }

    /// The folder with its trailing slash (or empty), and the file name.
    static func split(_ path: String) -> (dir: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    /// `IMG_1234(1).jpg` → (`IMG_1234.jpg`, `(1)`).
    static func splitDuplicate(_ name: String) -> (plain: String, number: String?) {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        guard let match = stem.range(of: #"\(\d+\)$"#, options: .regularExpression), match.lowerBound > stem.startIndex
        else { return (name, nil) }
        let plain = String(stem[..<match.lowerBound]) + (ext.isEmpty ? "" : "." + ext)
        return (plain, String(stem[match]))
    }
}
