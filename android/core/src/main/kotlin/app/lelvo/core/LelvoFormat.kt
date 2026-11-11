package app.lelvo.core

/** Versions of the storage contract (docs/CLOUD_FORMAT.md) this app reads and writes. */
object LelvoFormat {
    const val CAPTION_VERSION = 1
    val readableHeaderFormats = setOf(1, 2)
    const val WRITTEN_HEADER_FORMAT = 2
}
