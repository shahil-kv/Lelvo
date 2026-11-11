package app.lelvo.android.media

import android.content.Context
import android.net.Uri
import android.util.Size
import coil3.ImageLoader
import coil3.asImage
import coil3.decode.DataSource
import coil3.fetch.FetchResult
import coil3.fetch.Fetcher
import coil3.fetch.ImageFetchResult
import coil3.key.Keyer
import coil3.request.Options
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** A photo or video on this phone, as a grid tile: Android's own thumbnail, which it makes once and keeps. */
data class PhoneThumbnail(val uri: Uri)

class PhoneThumbnailFetcher(private val context: Context, private val data: PhoneThumbnail) : Fetcher {
    override suspend fun fetch(): FetchResult = withContext(Dispatchers.IO) {
        val bitmap = context.contentResolver.loadThumbnail(data.uri, Size(SIZE, SIZE), null)
        ImageFetchResult(bitmap.asImage(), isSampled = true, dataSource = DataSource.DISK)
    }

    class Factory(private val context: Context) : Fetcher.Factory<PhoneThumbnail> {
        override fun create(data: PhoneThumbnail, options: Options, imageLoader: ImageLoader): Fetcher = PhoneThumbnailFetcher(context, data)
    }

    // Big enough for two columns on a large phone; the grid's three columns use the same one.
    private companion object { const val SIZE = 512 }
}

class PhoneThumbnailKeyer : Keyer<PhoneThumbnail> {
    override fun key(data: PhoneThumbnail, options: Options) = "pt_${data.uri}"
}
