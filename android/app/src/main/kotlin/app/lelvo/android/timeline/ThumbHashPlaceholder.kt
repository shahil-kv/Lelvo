package app.lelvo.android.timeline

import android.graphics.Bitmap
import android.provider.Settings
import android.util.Base64
import android.util.LruCache
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import app.lelvo.core.format.ThumbHash
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Blurred stand-in for a cloud tile whose thumbnail has not loaded yet. Decoded off the main thread, only for
 * visible tiles that have a hash; kept in a small byte-bounded cache keyed by the hash string.
 */
object ThumbHashPlaceholder {
    private const val MAX_BYTES = 12 * 1024 * 1024

    private val cache = object : LruCache<String, ImageBitmap>(MAX_BYTES) {
        override fun sizeOf(key: String, value: ImageBitmap): Int = value.width * value.height * 4 + key.length * 2 + 64
    }
    private val bad = LruCache<String, Boolean>(256) // malformed hashes, so a bad one is not decoded again

    fun cached(hash: String): ImageBitmap? = cache.get(hash)

    /** Drops every decoded picture; they are rebuilt on demand. */
    fun trim() = cache.evictAll()

    /** Call off the main thread. Null for a malformed hash. */
    fun load(hash: String): ImageBitmap? {
        cache.get(hash)?.let { return it }
        if (bad.get(hash) != null) return null
        val image = try {
            Base64.decode(hash, Base64.DEFAULT).let(ThumbHash::decode)
        } catch (_: Exception) { null }
        val bitmap = image?.takeIf { it.width > 0 && it.height > 0 && it.rgba.size >= it.width * it.height * 4 }?.let(::toBitmap)
        if (bitmap == null) { bad.put(hash, true); return null }
        cache.put(hash, bitmap)
        return bitmap
    }

    private fun toBitmap(image: ThumbHash.Image): ImageBitmap {
        val n = image.width * image.height
        val pixels = IntArray(n)
        val p = image.rgba
        for (i in 0 until n) {
            // createBitmap(IntArray) takes straight (not premultiplied) ARGB and premultiplies itself.
            pixels[i] = ((p[i * 4 + 3].toInt() and 0xFF) shl 24) or ((p[i * 4].toInt() and 0xFF) shl 16) or
                ((p[i * 4 + 1].toInt() and 0xFF) shl 8) or (p[i * 4 + 2].toInt() and 0xFF)
        }
        return Bitmap.createBitmap(pixels, image.width, image.height, Bitmap.Config.ARGB_8888).asImageBitmap()
    }
}

/**
 * Drawn above the tile's real thumbnail: opaque until [loaded], then fades out in about 150 ms (at once when
 * animations are off). Draws nothing and starts no work when [hash] is null or the tile has loaded.
 */
@Composable
internal fun ThumbHashLayer(hash: String?, loaded: Boolean, modifier: Modifier) {
    if (hash == null) return
    val context = LocalContext.current
    val animate = remember { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f }
    val alpha by animateFloatAsState(if (loaded) 0f else 1f, if (animate) tween(150) else snap(), label = "thumbhash")
    if (loaded && alpha == 0f) return
    // Keyed by the hash, so a recycled tile never shows another photo's blur.
    val bitmap by produceState(ThumbHashPlaceholder.cached(hash), hash) {
        if (value == null) value = withContext(Dispatchers.Default) { ThumbHashPlaceholder.load(hash) }
    }
    bitmap?.let { Image(it, null, modifier.alpha(alpha), contentScale = ContentScale.Crop) }
}
