import Foundation

/// The rollout switch for writing `th` into new captions. Off until every user's app can read it (older builds ignore the
/// field, but a placeholder only helps once readers draw it). Reading, storing and drawing never depend on this.
public enum ThumbHashRollout {
    public static let writesToCaptions = false
}

/// ThumbHash: a placeholder for a photo in about 25 bytes (a blurred picture with the right colours and shape).
/// Port of Evan Wallace's reference implementation (MIT, github.com/evanw/thumbhash); credit in NOTICE.md.
/// Pure maths on RGBA bytes, so it lives here and both platforms turn it into an image themselves.
///
/// Reading is defensive on purpose: a hash comes from a caption written by another device, so a short or damaged one
/// returns nil instead of reading past its end.
public enum ThumbHash {
    /// The largest picture `encode` takes; bigger ones are slow with no benefit, so callers shrink first.
    public static let maxSide = 100

    public struct Image: Equatable, Sendable {
        public let width: Int
        public let height: Int
        /// Row by row, 4 bytes per pixel, not premultiplied.
        public let rgba: [UInt8]
    }

    @inline(__always) private static func round(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

    /// `rgba` is `width * height * 4` bytes, not premultiplied by alpha. Nil when the size is outside 1...100.
    public static func encode(width w: Int, height h: Int, rgba: [UInt8]) -> [UInt8]? {
        guard w >= 1, h >= 1, w <= maxSide, h <= maxSide, rgba.count == w * h * 4 else { return nil }
        var avgR = 0.0, avgG = 0.0, avgB = 0.0, avgA = 0.0
        for i in 0..<(w * h) {
            let j = i * 4
            let alpha = Double(rgba[j + 3]) / 255
            avgR += alpha / 255 * Double(rgba[j])
            avgG += alpha / 255 * Double(rgba[j + 1])
            avgB += alpha / 255 * Double(rgba[j + 2])
            avgA += alpha
        }
        if avgA > 0 { avgR /= avgA; avgG /= avgA; avgB /= avgA }

        let hasAlpha = avgA < Double(w * h)
        let lLimit = hasAlpha ? 5.0 : 7.0
        let longest = Double(max(w, h))
        let lx = max(1, round(lLimit * Double(w) / longest))
        let ly = max(1, round(lLimit * Double(h) / longest))
        var l = [Double](repeating: 0, count: w * h)
        var p = l, q = l, a = l
        for i in 0..<(w * h) {
            let j = i * 4
            let alpha = Double(rgba[j + 3]) / 255
            let r = avgR * (1 - alpha) + alpha / 255 * Double(rgba[j])
            let g = avgG * (1 - alpha) + alpha / 255 * Double(rgba[j + 1])
            let b = avgB * (1 - alpha) + alpha / 255 * Double(rgba[j + 2])
            l[i] = (r + g + b) / 3
            p[i] = (r + g) / 2 - b
            q[i] = r - g
            a[i] = alpha
        }

        func channel(_ values: [Double], _ nx: Int, _ ny: Int) -> (dc: Double, ac: [Double], scale: Double) {
            var dc = 0.0, ac: [Double] = [], scale = 0.0
            var fx = [Double](repeating: 0, count: w)
            for cy in 0..<ny {
                var cx = 0
                while cx * ny < nx * (ny - cy) {
                    var f = 0.0
                    for x in 0..<w { fx[x] = cos(Double.pi / Double(w) * Double(cx) * (Double(x) + 0.5)) }
                    for y in 0..<h {
                        let fy = cos(Double.pi / Double(h) * Double(cy) * (Double(y) + 0.5))
                        for x in 0..<w { f += values[x + y * w] * fx[x] * fy }
                    }
                    f /= Double(w * h)
                    if cx != 0 || cy != 0 { ac.append(f); scale = max(scale, abs(f)) } else { dc = f }
                    cx += 1
                }
            }
            if scale > 0 { for i in ac.indices { ac[i] = 0.5 + 0.5 / scale * ac[i] } }
            return (dc, ac, scale)
        }
        let lc = channel(l, max(3, lx), max(3, ly))
        let pc = channel(p, 3, 3)
        let qc = channel(q, 3, 3)
        let ac = hasAlpha ? channel(a, 5, 5) : (dc: 0.0, ac: [Double](), scale: 0.0)

        let isLandscape = w > h
        let header24 = round(63 * lc.dc) | (round(31.5 + 31.5 * pc.dc) << 6) | (round(31.5 + 31.5 * qc.dc) << 12)
            | (round(31 * lc.scale) << 18) | ((hasAlpha ? 1 : 0) << 23)
        let header16 = (isLandscape ? ly : lx) | (round(63 * pc.scale) << 3) | (round(63 * qc.scale) << 9) | ((isLandscape ? 1 : 0) << 15)
        var hash: [UInt8] = [UInt8(header24 & 255), UInt8((header24 >> 8) & 255), UInt8(header24 >> 16),
                             UInt8(header16 & 255), UInt8(header16 >> 8)]
        let acStart = hasAlpha ? 6 : 5
        if hasAlpha { hash.append(UInt8(round(15 * ac.dc) | (round(15 * ac.scale) << 4))) }
        var acIndex = 0
        for factors in (hasAlpha ? [lc.ac, pc.ac, qc.ac, ac.ac] : [lc.ac, pc.ac, qc.ac]) {
            for f in factors {
                let index = acStart + (acIndex >> 1)
                while hash.count <= index { hash.append(0) }
                hash[index] |= UInt8(round(15 * f) << ((acIndex & 1) << 2))
                acIndex += 1
            }
        }
        return hash
    }

    /// The bytes a hash with these header bits needs, or nil when the header can't be a ThumbHash.
    private static func layout(_ hash: [UInt8]) -> (lx: Int, ly: Int, hasAlpha: Bool, isLandscape: Bool, acStart: Int, needed: Int)? {
        guard hash.count >= 5 else { return nil }
        let header24 = Int(hash[0]) | (Int(hash[1]) << 8) | (Int(hash[2]) << 16)
        let header16 = Int(hash[3]) | (Int(hash[4]) << 8)
        let hasAlpha = (header24 >> 23) != 0
        let isLandscape = (header16 >> 15) != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7)
        let ly = max(3, isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7))
        func count(_ nx: Int, _ ny: Int) -> Int {
            var n = 0
            for cy in 0..<ny { var cx = cy == 0 ? 1 : 0; while cx * ny < nx * (ny - cy) { n += 1; cx += 1 } }
            return n
        }
        let acCount = count(lx, ly) + 2 * count(3, 3) + (hasAlpha ? count(5, 5) : 0)
        let acStart = hasAlpha ? 6 : 5
        return (lx, ly, hasAlpha, isLandscape, acStart, acStart + (acCount + 1) / 2)
    }

    /// A 32-pixel-wide placeholder, or nil for a hash that is too short or damaged.
    public static func decode(_ hash: [UInt8]) -> Image? {
        guard let layout = layout(hash), hash.count >= layout.needed else { return nil }
        let header24 = Int(hash[0]) | (Int(hash[1]) << 8) | (Int(hash[2]) << 16)
        let header16 = Int(hash[3]) | (Int(hash[4]) << 8)
        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let hasAlpha = layout.hasAlpha
        let aDC = hasAlpha ? Double(hash[5] & 15) / 15 : 1
        let aScale = Double(hash[5] >> 4) / 15
        let lx = layout.lx, ly = layout.ly

        var acIndex = 0
        func readChannel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double] {
            var ac: [Double] = []
            for cy in 0..<ny {
                var cx = cy == 0 ? 1 : 0
                while cx * ny < nx * (ny - cy) {
                    let byte = Int(hash[layout.acStart + (acIndex >> 1)])
                    ac.append((Double((byte >> ((acIndex & 1) << 2)) & 15) / 7.5 - 1) * scale)
                    acIndex += 1
                    cx += 1
                }
            }
            return ac
        }
        let lAC = readChannel(lx, ly, lScale)
        let pAC = readChannel(3, 3, pScale * 1.25)
        let qAC = readChannel(3, 3, qScale * 1.25)
        let aAC = hasAlpha ? readChannel(5, 5, aScale) : []

        let ratio = Double(layout.isLandscape ? (hasAlpha ? 5 : 7) : Int(hash[3]) & 7) / Double(layout.isLandscape ? Int(hash[3]) & 7 : (hasAlpha ? 5 : 7))
        guard ratio.isFinite, ratio > 0 else { return nil }
        let w = round(ratio > 1 ? 32 : 32 * ratio)
        let h = round(ratio > 1 ? 32 / ratio : 32)
        guard w >= 1, h >= 1 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var fx = [Double](repeating: 0, count: max(lx, hasAlpha ? 5 : 3))
        var fy = [Double](repeating: 0, count: max(ly, hasAlpha ? 5 : 3))
        var i = 0
        for y in 0..<h {
            for x in 0..<w {
                var l = lDC, p = pDC, q = qDC, a = aDC
                for cx in 0..<fx.count { fx[cx] = cos(Double.pi / Double(w) * (Double(x) + 0.5) * Double(cx)) }
                for cy in 0..<fy.count { fy[cy] = cos(Double.pi / Double(h) * (Double(y) + 0.5) * Double(cy)) }
                var j = 0
                for cy in 0..<ly {
                    var cx = cy == 0 ? 1 : 0
                    let fy2 = fy[cy] * 2
                    while cx * ly < lx * (ly - cy) { l += lAC[j] * fx[cx] * fy2; cx += 1; j += 1 }
                }
                j = 0
                for cy in 0..<3 {
                    var cx = cy == 0 ? 1 : 0
                    let fy2 = fy[cy] * 2
                    while cx < 3 - cy { let f = fx[cx] * fy2; p += pAC[j] * f; q += qAC[j] * f; cx += 1; j += 1 }
                }
                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        var cx = cy == 0 ? 1 : 0
                        let fy2 = fy[cy] * 2
                        while cx < 5 - cy { a += aAC[j] * fx[cx] * fy2; cx += 1; j += 1 }
                    }
                }
                let b = l - 2.0 / 3 * p
                let r = (3 * l - b + q) / 2
                let g = r - q
                func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, 255 * min(1, v)))) }
                rgba[i] = byte(r); rgba[i + 1] = byte(g); rgba[i + 2] = byte(b); rgba[i + 3] = byte(a)
                i += 4
            }
        }
        return Image(width: w, height: h, rgba: rgba)
    }

    /// Width over height of the original, as far as the hash remembers it; nil for a damaged hash.
    public static func aspectRatio(_ hash: [UInt8]) -> Double? {
        guard let layout = layout(hash), hash.count >= layout.needed else { return nil }
        let side = Int(hash[3]) & 7
        let lx = layout.isLandscape ? (layout.hasAlpha ? 5 : 7) : side
        let ly = layout.isLandscape ? side : (layout.hasAlpha ? 5 : 7)
        guard lx > 0, ly > 0 else { return nil }
        return Double(lx) / Double(ly)
    }
}
