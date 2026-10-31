import Foundation

/// What a restore into Photos needs for one item, and how each stored file goes back (docs/CLOUD_FORMAT.md §2).
/// The goal is the photo as it was: the untouched original, its edit shown and revertible, the RAW of a RAW + JPEG
/// pair, the Live Photo's video, favourite, hidden and albums. Items backed up before some of these were stored come
/// back with what they have.
public struct RestorePlan: Equatable, Sendable {
    /// The rendered edit, applied as a revertible edit on top of the original.
    public struct Edit: Equatable, Sendable {
        /// The rendered still or video (role `e`).
        public var rendered: String = "e"
        /// Photos' own adjustment data (role `ad`), when it was backed up.
        public var adjustment: String?
        /// An edited Live Photo's rendered video (role `epv`), when it was backed up.
        public var pairedVideo: String?

        public init(rendered: String = "e", adjustment: String? = nil, pairedVideo: String? = nil) {
            self.rendered = rendered
            self.adjustment = adjustment
            self.pairedVideo = pairedVideo
        }
    }

    public var kind: MediaKind
    public var original = "o"
    /// The Live Photo's video (role `pv`).
    public var pairedVideo: String?
    /// The RAW of a RAW + JPEG pair (role `ra`).
    public var rawAlternate: String?
    public var edit: Edit?
    /// Albums that didn't fit the caption are in role `md`.
    public var metadata: String?
    public var favorite: Bool
    public var hidden: Bool
    public var albums: [String]

    /// The files to download, original first.
    public var downloads: [String] {
        [original, pairedVideo, rawAlternate, edit?.rendered, edit?.adjustment, edit?.pairedVideo, metadata].compactMap { $0 }
    }

    public static func make(for item: MediaItem) -> RestorePlan {
        let legacy = item.cloudParts == nil
        func has(_ role: String) -> Bool { !legacy && !item.parts(role).isEmpty }
        var plan = RestorePlan(kind: item.kind, favorite: item.favorite == true, hidden: item.hidden == true, albums: item.albums ?? [])
        if item.kind == .livePhoto, legacy ? item.pairedVideo != nil : has("pv") { plan.pairedVideo = "pv" }
        if item.kind != .video, has("ra") { plan.rawAlternate = "ra" }
        if item.hasEdit == true, has("e") {
            plan.edit = Edit(adjustment: has("ad") ? "ad" : nil,
                             pairedVideo: item.kind == .livePhoto && has("epv") ? "epv" : nil)
        }
        if has("md") { plan.metadata = "md" }
        return plan
    }
}
