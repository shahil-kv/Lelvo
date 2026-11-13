package app.lelvo.android.media

import app.lelvo.core.index.LibraryItem
import app.lelvo.data.media.CloudMedia
import coil3.ImageLoader
import coil3.decode.DataSource
import coil3.decode.ImageSource
import coil3.fetch.FetchResult
import coil3.fetch.Fetcher
import coil3.fetch.SourceFetchResult
import coil3.key.Keyer
import coil3.request.Options
import okio.FileSystem
import okio.Path.Companion.toOkioPath
import java.io.File

/** A cloud item's thumbnail, for `AsyncImage(model = …)`. */
data class CloudThumbnail(val item: LibraryItem)

/** The photo the viewer shows: the screen copy ([screenCopy]) or the displayed original. */
data class CloudPhoto(val item: LibraryItem, val screenCopy: Boolean = false)

/**
 * Coil reads cloud images through [CloudMedia]: downloaded from Telegram, decrypted and cached on disk there, then
 * decoded by Coil like any file. Coil keeps the decoded bitmaps in memory by the keys below.
 */
class CloudImageFetcher(private val file: suspend () -> File, private val cached: Boolean) : Fetcher {
    override suspend fun fetch(): FetchResult =
        SourceFetchResult(ImageSource(file().toOkioPath(), FileSystem.SYSTEM), null, if (cached) DataSource.DISK else DataSource.NETWORK)

    class ThumbnailFactory(private val media: CloudMedia) : Fetcher.Factory<CloudThumbnail> {
        override fun create(data: CloudThumbnail, options: Options, imageLoader: ImageLoader): Fetcher =
            CloudImageFetcher({ media.thumbnail(data.item) }, media.cachedThumbnail(data.item) != null)
    }

    class PhotoFactory(private val media: CloudMedia) : Fetcher.Factory<CloudPhoto> {
        override fun create(data: CloudPhoto, options: Options, imageLoader: ImageLoader): Fetcher =
            CloudImageFetcher(
                { if (data.screenCopy) media.screenCopy(data.item) else media.displayed(data.item) },
                !data.screenCopy && media.cachedDisplayed(data.item) != null,
            )
    }
}

class CloudThumbnailKeyer : Keyer<CloudThumbnail> {
    override fun key(data: CloudThumbnail, options: Options) = "t_${data.item.id}"
}

class CloudPhotoKeyer : Keyer<CloudPhoto> {
    override fun key(data: CloudPhoto, options: Options) = "p_${data.item.id}_${if (data.screenCopy) "d" else "o"}"
}
