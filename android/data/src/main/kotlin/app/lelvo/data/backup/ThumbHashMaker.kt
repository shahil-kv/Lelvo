package app.lelvo.data.backup

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import app.lelvo.core.format.ThumbHash

/**
 * Makes the Base64 ThumbHash a caption carries (`th`) from the upload's thumbnail JPEG: shrunk to 100 px, then the maths in
 * `ThumbHash` (iOS `ThumbHashMaker`). A thumbnail that can't be read gives null, and the caption simply has no `th`.
 */
object ThumbHashMaker {
    fun fromJpeg(jpeg: ByteArray): String? {
        val decoded = runCatching { BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) }.getOrNull() ?: return null
        val longest = maxOf(decoded.width, decoded.height)
        if (longest < 1) return null
        val scale = minOf(1f, ThumbHash.MAX_SIDE.toFloat() / longest)
        val w = maxOf(1, (decoded.width * scale).toInt())
        val h = maxOf(1, (decoded.height * scale).toInt())
        val small = if (w == decoded.width && h == decoded.height) decoded else Bitmap.createScaledBitmap(decoded, w, h, true)
        val pixels = IntArray(w * h)
        small.getPixels(pixels, 0, w, 0, 0, w, h)
        // A photo thumbnail is opaque, so straight and premultiplied alpha are the same bytes.
        val rgba = ByteArray(w * h * 4)
        for (i in pixels.indices) {
            val p = pixels[i]
            rgba[i * 4] = ((p shr 16) and 0xFF).toByte()
            rgba[i * 4 + 1] = ((p shr 8) and 0xFF).toByte()
            rgba[i * 4 + 2] = (p and 0xFF).toByte()
            rgba[i * 4 + 3] = ((p shr 24) and 0xFF).toByte()
        }
        val hash = ThumbHash.encode(w, h, rgba) ?: return null
        return java.util.Base64.getEncoder().encodeToString(hash)
    }
}
