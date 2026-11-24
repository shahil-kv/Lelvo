package app.lelvo.core.format

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * ThumbHash: a placeholder for a photo in about 25 bytes (a blurred picture with the right colours and shape).
 * Port of Evan Wallace's reference implementation (MIT, github.com/evanw/thumbhash), as iOS `ThumbHash`; credit in
 * NOTICE.md. Pure maths on RGBA bytes: each platform turns the result into an image itself.
 *
 * Reading is defensive on purpose: a hash comes from a caption written by another device, so a short or damaged one
 * returns null instead of reading past its end.
 */
object ThumbHash {
    /** The largest picture [encode] takes; bigger ones are slow with no benefit, so callers shrink first. */
    const val MAX_SIDE = 100

    /**
     * The rollout switch for writing `th` into new captions (iOS `ThumbHashRollout`). Off until every user's app can read it.
     * Reading, storing and drawing never depend on it.
     */
    const val WRITES_TO_CAPTIONS = false

    class Image(val width: Int, val height: Int, /** Row by row, 4 bytes per pixel, not premultiplied. */ val rgba: ByteArray)

    private fun round(x: Double): Int = floor(x + 0.5).toInt()

    /** [rgba] is `width * height * 4` bytes, not premultiplied by alpha. Null when the size is outside 1..100. */
    fun encode(w: Int, h: Int, rgba: ByteArray): ByteArray? {
        if (w < 1 || h < 1 || w > MAX_SIDE || h > MAX_SIDE || rgba.size != w * h * 4) return null
        fun px(i: Int) = rgba[i].toInt() and 0xFF
        var avgR = 0.0; var avgG = 0.0; var avgB = 0.0; var avgA = 0.0
        for (i in 0 until w * h) {
            val j = i * 4
            val alpha = px(j + 3) / 255.0
            avgR += alpha / 255 * px(j); avgG += alpha / 255 * px(j + 1); avgB += alpha / 255 * px(j + 2); avgA += alpha
        }
        if (avgA > 0) { avgR /= avgA; avgG /= avgA; avgB /= avgA }

        val hasAlpha = avgA < w * h
        val lLimit = if (hasAlpha) 5.0 else 7.0
        val longest = max(w, h).toDouble()
        val lx = max(1, round(lLimit * w / longest))
        val ly = max(1, round(lLimit * h / longest))
        val l = DoubleArray(w * h); val p = DoubleArray(w * h); val q = DoubleArray(w * h); val a = DoubleArray(w * h)
        for (i in 0 until w * h) {
            val j = i * 4
            val alpha = px(j + 3) / 255.0
            val r = avgR * (1 - alpha) + alpha / 255 * px(j)
            val g = avgG * (1 - alpha) + alpha / 255 * px(j + 1)
            val b = avgB * (1 - alpha) + alpha / 255 * px(j + 2)
            l[i] = (r + g + b) / 3; p[i] = (r + g) / 2 - b; q[i] = r - g; a[i] = alpha
        }

        class Channel(val dc: Double, val ac: List<Double>, val scale: Double)
        fun channel(values: DoubleArray, nx: Int, ny: Int): Channel {
            var dc = 0.0; var scale = 0.0
            val ac = ArrayList<Double>()
            val fx = DoubleArray(w)
            for (cy in 0 until ny) {
                var cx = 0
                while (cx * ny < nx * (ny - cy)) {
                    var f = 0.0
                    for (x in 0 until w) fx[x] = cos(PI / w * cx * (x + 0.5))
                    for (y in 0 until h) {
                        val fy = cos(PI / h * cy * (y + 0.5))
                        for (x in 0 until w) f += values[x + y * w] * fx[x] * fy
                    }
                    f /= (w * h).toDouble()
                    if (cx != 0 || cy != 0) { ac += f; scale = max(scale, abs(f)) } else dc = f
                    cx++
                }
            }
            if (scale > 0) for (i in ac.indices) ac[i] = 0.5 + 0.5 / scale * ac[i]
            return Channel(dc, ac, scale)
        }
        val lc = channel(l, max(3, lx), max(3, ly))
        val pc = channel(p, 3, 3)
        val qc = channel(q, 3, 3)
        val ac = if (hasAlpha) channel(a, 5, 5) else Channel(0.0, emptyList(), 0.0)

        val isLandscape = w > h
        val header24 = round(63 * lc.dc) or (round(31.5 + 31.5 * pc.dc) shl 6) or (round(31.5 + 31.5 * qc.dc) shl 12) or
            (round(31 * lc.scale) shl 18) or ((if (hasAlpha) 1 else 0) shl 23)
        val header16 = (if (isLandscape) ly else lx) or (round(63 * pc.scale) shl 3) or (round(63 * qc.scale) shl 9) or
            ((if (isLandscape) 1 else 0) shl 15)
        val hash = arrayListOf(header24 and 255, (header24 shr 8) and 255, header24 shr 16, header16 and 255, header16 shr 8)
        val acStart = if (hasAlpha) 6 else 5
        if (hasAlpha) hash += round(15 * ac.dc) or (round(15 * ac.scale) shl 4)
        var acIndex = 0
        for (factors in if (hasAlpha) listOf(lc.ac, pc.ac, qc.ac, ac.ac) else listOf(lc.ac, pc.ac, qc.ac)) {
            for (f in factors) {
                val index = acStart + (acIndex shr 1)
                while (hash.size <= index) hash += 0
                hash[index] = hash[index] or (round(15 * f) shl ((acIndex and 1) shl 2))
                acIndex++
            }
        }
        return ByteArray(hash.size) { hash[it].toByte() }
    }

    private class Layout(val lx: Int, val ly: Int, val hasAlpha: Boolean, val isLandscape: Boolean, val acStart: Int, val needed: Int)

    private fun count(nx: Int, ny: Int): Int {
        var n = 0
        for (cy in 0 until ny) { var cx = if (cy == 0) 1 else 0; while (cx * ny < nx * (ny - cy)) { n++; cx++ } }
        return n
    }

    private fun layout(hash: ByteArray): Layout? {
        if (hash.size < 5) return null
        fun b(i: Int) = hash[i].toInt() and 0xFF
        val header24 = b(0) or (b(1) shl 8) or (b(2) shl 16)
        val header16 = b(3) or (b(4) shl 8)
        val hasAlpha = (header24 shr 23) != 0
        val isLandscape = (header16 shr 15) != 0
        val lx = max(3, if (isLandscape) (if (hasAlpha) 5 else 7) else header16 and 7)
        val ly = max(3, if (isLandscape) header16 and 7 else (if (hasAlpha) 5 else 7))
        val acCount = count(lx, ly) + 2 * count(3, 3) + (if (hasAlpha) count(5, 5) else 0)
        val acStart = if (hasAlpha) 6 else 5
        return Layout(lx, ly, hasAlpha, isLandscape, acStart, acStart + (acCount + 1) / 2)
    }

    /** A 32-pixel-wide placeholder, or null for a hash that is too short or damaged. */
    fun decode(hash: ByteArray): Image? {
        val layout = layout(hash)?.takeIf { hash.size >= it.needed } ?: return null
        fun b(i: Int) = hash[i].toInt() and 0xFF
        val header24 = b(0) or (b(1) shl 8) or (b(2) shl 16)
        val header16 = b(3) or (b(4) shl 8)
        val lDC = (header24 and 63) / 63.0
        val pDC = ((header24 shr 6) and 63) / 31.5 - 1
        val qDC = ((header24 shr 12) and 63) / 31.5 - 1
        val lScale = ((header24 shr 18) and 31) / 31.0
        val pScale = ((header16 shr 3) and 63) / 63.0
        val qScale = ((header16 shr 9) and 63) / 63.0
        val hasAlpha = layout.hasAlpha
        val aDC = if (hasAlpha) (b(5) and 15) / 15.0 else 1.0
        val aScale = (b(5) shr 4) / 15.0
        val lx = layout.lx; val ly = layout.ly

        var acIndex = 0
        fun readChannel(nx: Int, ny: Int, scale: Double): DoubleArray {
            val ac = ArrayList<Double>()
            for (cy in 0 until ny) {
                var cx = if (cy == 0) 1 else 0
                while (cx * ny < nx * (ny - cy)) {
                    val byte = b(layout.acStart + (acIndex shr 1))
                    ac += (((byte shr ((acIndex and 1) shl 2)) and 15) / 7.5 - 1) * scale
                    acIndex++
                    cx++
                }
            }
            return ac.toDoubleArray()
        }
        val lAC = readChannel(lx, ly, lScale)
        val pAC = readChannel(3, 3, pScale * 1.25)
        val qAC = readChannel(3, 3, qScale * 1.25)
        val aAC = if (hasAlpha) readChannel(5, 5, aScale) else DoubleArray(0)

        val side = b(3) and 7
        val rlx = if (layout.isLandscape) (if (hasAlpha) 5 else 7) else side
        val rly = if (layout.isLandscape) side else (if (hasAlpha) 5 else 7)
        if (rlx <= 0 || rly <= 0) return null
        val ratio = rlx.toDouble() / rly
        val w = round(if (ratio > 1) 32.0 else 32 * ratio)
        val h = round(if (ratio > 1) 32 / ratio else 32.0)
        if (w < 1 || h < 1) return null
        val out = ByteArray(w * h * 4)
        val fx = DoubleArray(max(lx, if (hasAlpha) 5 else 3))
        val fy = DoubleArray(max(ly, if (hasAlpha) 5 else 3))
        fun byte(v: Double): Byte = max(0.0, min(255.0, 255 * min(1.0, v))).toInt().toByte()
        var i = 0
        for (y in 0 until h) for (x in 0 until w) {
            var l = lDC; var p = pDC; var q = qDC; var a = aDC
            for (cx in fx.indices) fx[cx] = cos(PI / w * (x + 0.5) * cx)
            for (cy in fy.indices) fy[cy] = cos(PI / h * (y + 0.5) * cy)
            var j = 0
            for (cy in 0 until ly) {
                var cx = if (cy == 0) 1 else 0
                val fy2 = fy[cy] * 2
                while (cx * ly < lx * (ly - cy)) { l += lAC[j] * fx[cx] * fy2; cx++; j++ }
            }
            j = 0
            for (cy in 0 until 3) {
                var cx = if (cy == 0) 1 else 0
                val fy2 = fy[cy] * 2
                while (cx < 3 - cy) { val f = fx[cx] * fy2; p += pAC[j] * f; q += qAC[j] * f; cx++; j++ }
            }
            if (hasAlpha) {
                j = 0
                for (cy in 0 until 5) {
                    var cx = if (cy == 0) 1 else 0
                    val fy2 = fy[cy] * 2
                    while (cx < 5 - cy) { a += aAC[j] * fx[cx] * fy2; cx++; j++ }
                }
            }
            val bl = l - 2.0 / 3 * p
            val r = (3 * l - bl + q) / 2
            val g = r - q
            out[i] = byte(r); out[i + 1] = byte(g); out[i + 2] = byte(bl); out[i + 3] = byte(a)
            i += 4
        }
        return Image(w, h, out)
    }

    /** Width over height of the original, as far as the hash remembers it; null for a damaged hash. */
    fun aspectRatio(hash: ByteArray): Double? {
        val layout = layout(hash)?.takeIf { hash.size >= it.needed } ?: return null
        val side = hash[3].toInt() and 7
        val lx = if (layout.isLandscape) (if (layout.hasAlpha) 5 else 7) else side
        val ly = if (layout.isLandscape) side else (if (layout.hasAlpha) 5 else 7)
        if (lx <= 0 || ly <= 0) return null
        return lx.toDouble() / ly
    }
}
