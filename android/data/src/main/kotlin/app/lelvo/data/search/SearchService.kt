package app.lelvo.data.search

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.MediaStore
import app.lelvo.core.index.PhoneAsset
import app.lelvo.core.search.SearchMatcher
import app.lelvo.core.support.AppLog
import app.lelvo.data.index.LibraryStore
import app.lelvo.data.media.PhotoAccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale
import kotlin.coroutines.resume

/**
 * What search needs beyond the index (iOS `SearchService`): where each photo on this phone was taken, and place names.
 *
 * iOS gets a photo's location from PhotoKit for free; Android hides it from MediaStore since Android 10, so each file's
 * own location is read once (EXIF for photos, the video's location tag) and kept until the file changes. Place names
 * are looked up once per ~1 km area with the phone's geocoder, which receives only the middle of that area, never a
 * photo's own location. Both are caches: losing them costs a re-read, nothing else.
 */
class SearchService(context: Context, private val store: LibraryStore, private val photos: PhotoAccess) {
    private val app = context.applicationContext
    private val dir = File(app.cacheDir, "search")
    private val placesFile = File(dir, "places.json")
    private val locationsFile = File(dir, "locations.json")
    private val labels = PhotoLabels(context, photos, dir)
    private val running = Mutex()

    /** A phone file's location as read; [lat] NaN means it has none. */
    private data class Location(val stamp: Long, val lat: Double, val lon: Double)

    @Volatile private var places: Map<String, String>? = null
    @Volatile private var locations: Map<String, Location>? = null

    data class Status(val read: Int, val total: Int)

    private val _status = MutableStateFlow(Status(0, 0))
    /** (read, to read) of phone photos' places, for Search's footer. */
    val status: StateFlow<Status> = _status

    private val _revision = MutableStateFlow(0)
    /** Bumped when new places or names are known, so Search and Memories rebuild. */
    val revision: StateFlow<Int> = _revision

    /** Where a photo on this phone was taken, if it says and was read. */
    fun phoneLocation(localId: String): Pair<Double, Double>? =
        loadLocations()[localId]?.takeIf { !it.lat.isNaN() }?.let { it.lat to it.lon }

    /** Every known area name: cell → "City, State, Country". */
    fun placeNames(): Map<String, String> = loadPlaces()

    /** The name of a `placeCell` (its first part, e.g. the city), if it was looked up. */
    fun placeName(cell: String): String? = loadPlaces()[cell]?.substringBefore(',')?.trim()?.takeIf { it.isNotEmpty() }

    /**
     * Reads places not read yet (or changed since), then names new areas. One pass at a time; a second call while one
     * runs returns at once. Runs while the app is open (the caller cancels it when the app leaves the screen), not in
     * battery saver. [phone] false (the demo) names the library's places but doesn't read this phone's photos.
     */
    suspend fun index(phone: Boolean = true) {
        if (!running.tryLock()) return
        try { withContext(Dispatchers.IO) { if (phone) { readPlaces(); readThings() }; lookUpNames() } } finally { running.unlock() }
    }

    /** Things in a phone photo ("dog", "beach"), by MediaStore id, for search and themed Memories. */
    fun things(localId: String): List<String> = labels.of(localId)

    /** After the places: they are quick and name the photos first. Not on battery saver, like the places. */
    private suspend fun readThings() {
        if (powerSaving()) return
        var last = System.currentTimeMillis()
        val read = labels.read(photos.assets()) { _, _ ->
            // New words show while a long first pass runs, not only at its end.
            if (System.currentTimeMillis() - last > 20_000) { last = System.currentTimeMillis(); _revision.value++ }
        }
        if (read > 0) _revision.value++
    }

    private suspend fun readPlaces() {
        if (powerSaving()) return
        val started = System.currentTimeMillis()
        val assets = photos.assets()
        val known = HashMap(loadLocations())
        // Photos that left the phone leave the cache.
        val present = assets.mapTo(HashSet()) { it.localId }
        val gone = known.keys.count { it !in present }
        known.keys.retainAll(present)
        val todo = assets.filter { known[it.localId]?.stamp != stamp(it) }
        // Without "Allow access to location" Android removes the place from every file: nothing worth reading.
        if (app.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            _status.value = Status(assets.size - todo.size, assets.size)
            if (gone > 0) save(known)
            return
        }
        _status.value = Status(assets.size - todo.size, assets.size)
        var done = 0
        var lastNotice = System.currentTimeMillis()
        try { for (a in todo) {
            kotlin.coroutines.coroutineContext.ensureActive()
            if (powerSaving()) break
            val loc = runCatching { read(a) }.getOrElse {
                // Not allowed (permission taken back mid-way): stop, and read again next time.
                if (it is SecurityException) null else Location(stamp(a), Double.NaN, Double.NaN)
            } ?: break
            known[a.localId] = loc
            done++
            _status.value = Status(assets.size - todo.size + done, assets.size)
            if (System.currentTimeMillis() - lastNotice > 20_000) {
                lastNotice = System.currentTimeMillis()
                save(known)
                _revision.value++
            }
            // On battery, leave room for everything else the phone is doing.
            if (!charging()) delay(5)
        } } finally {
            // Also when the app leaves the screen mid-way: what was read stays read.
            if (done > 0 || gone > 0) save(known)
            if (done > 0) _revision.value++
        }
        if (todo.isNotEmpty()) AppLog.info("Search index: read the place of %d of %d new photos (%d known) in %.0f s".format(
            done, todo.size, known.count { !it.value.lat.isNaN() }, (System.currentTimeMillis() - started) / 1000.0))
    }

    private fun stamp(a: PhoneAsset) = a.modifiedAt ?: 0

    private fun read(a: PhoneAsset): Location {
        val uri = photos.uri(a)
        // Without the original, Android removes the location from what an app reads.
        val original = MediaStore.setRequireOriginal(uri)
        val latLon: Pair<Double, Double>? = if (a.isVideo) {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(app, original)
                r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)?.let(SearchMatcher::parseIso6709)
            } finally { r.release() }
        } else {
            app.contentResolver.openInputStream(original)?.use { s ->
                val out = FloatArray(2)
                if (ExifInterface(s).getLatLong(out)) out[0].toDouble() to out[1].toDouble() else null
            }
        }
        val ok = latLon?.takeIf { (lat, lon) -> !(lat == 0.0 && lon == 0.0) && lat in -90.0..90.0 && lon in -180.0..180.0 }
        return Location(stamp(a), ok?.first ?: Double.NaN, ok?.second ?: Double.NaN)
    }

    /** Names for areas not looked up yet, one request at a time with a pause between, as iOS does with Apple's. */
    private suspend fun lookUpNames() {
        if (!Geocoder.isPresent()) { AppLog.info("Search index: this phone has no geocoder, so places have no names"); return }
        if (!online()) return
        val centres = LinkedHashMap<String, Pair<Double, Double>>()
        fun add(lat: Double, lon: Double) {
            val cell = SearchMatcher.placeCell(lat, lon)
            // The geocoder gets the middle of the ~1 km area, never a photo's own location.
            if (cell !in centres) centres[cell] = cell.substringBefore(',').toDouble() to cell.substringAfter(',').toDouble()
        }
        for (l in loadLocations().values) if (!l.lat.isNaN()) add(l.lat, l.lon)
        for (i in store.allItems()) {
            val lat = i.latitude ?: continue
            val lon = i.longitude ?: continue
            if (!(lat == 0.0 && lon == 0.0)) add(lat, lon)
        }
        val known = HashMap(loadPlaces())
        val missing = centres.keys.filter { it !in known }
        if (missing.isEmpty()) return
        val geocoder = Geocoder(app, Locale.getDefault())
        AppLog.info("Search index: naming ${missing.size} new places")
        var found = 0
        var failed = 0
        var inARow = 0
        for (cell in missing) {
            kotlin.coroutines.coroutineContext.ensureActive()
            if (!online()) break
            val (lat, lon) = centres.getValue(cell)
            val result = runCatching { geocode(geocoder, lat, lon) }
            if (result.isFailure) {
                if (failed++ == 0) AppLog.warn("Search index: the geocoder failed: ${result.exceptionOrNull()?.let { it::class.simpleName }}")
                // Three in a row: the geocoder can't be reached (seen on an emulator whose Play services had no
                // network). The rest wait for the next pass instead of each waiting for its own failure.
                if (++inARow >= 3) break
            } else inARow = 0
            val address = result.getOrNull()
            if (address != null) {
                val parts = listOfNotNull(address.locality ?: address.subAdminArea, address.adminArea, address.countryName, address.subLocality)
                    .map { it.trim() }.filter { it.isNotEmpty() }.distinct()
                if (parts.isNotEmpty()) {
                    known[cell] = parts.joinToString(", ")
                    found++
                    places = HashMap(known)
                    // Names show as they come, not only at the end of a long first run.
                    if (found % 10 == 0) { savePlaces(known); _revision.value++ }
                }
            }
            delay(1_200)
        }
        savePlaces(known)
        if (found > 0) _revision.value++
        AppLog.info("Search index: named $found of ${missing.size} new places")
    }

    private suspend fun geocode(geocoder: Geocoder, lat: Double, lon: Double): Address? =
        if (Build.VERSION.SDK_INT >= 33) withTimeoutOrNull(15_000) {
            suspendCancellableCoroutine { cont ->
                geocoder.getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<Address>) { if (cont.isActive) cont.resume(addresses.firstOrNull()) }
                    override fun onError(errorMessage: String?) { if (cont.isActive) cont.resumeWith(Result.failure(java.io.IOException("geocoder error"))) }
                })
            }
        } else @Suppress("DEPRECATION") geocoder.getFromLocation(lat, lon, 1)?.firstOrNull()

    /** Sign out and reset: what was read about this phone's photos goes too. */
    fun clear() {
        places = emptyMap()
        locations = emptyMap()
        labels.clear()
        dir.deleteRecursively()
        _status.value = Status(0, 0)
        _revision.value++
    }

    // MARK: storage

    private fun loadPlaces(): Map<String, String> = places ?: synchronized(this) {
        places ?: runCatching {
            val o = JSONObject(placesFile.readText())
            o.keys().asSequence().associateWith { o.getString(it) }
        }.getOrDefault(emptyMap()).also { places = it }
    }

    /** Where each phone photo was taken, by MediaStore id, as the index read it from the files (for the map). */
    suspend fun phoneLocations(): Map<String, Pair<Double, Double>> = withContext(Dispatchers.IO) {
        loadLocations().entries.mapNotNull { (id, l) -> if (l.lat.isNaN()) null else id to (l.lat to l.lon) }.toMap()
    }

    private fun loadLocations(): Map<String, Location> = locations ?: synchronized(this) {
        locations ?: runCatching {
            val o = JSONObject(locationsFile.readText())
            o.keys().asSequence().associateWith { k ->
                val a = o.getJSONArray(k)
                Location(a.getLong(0), a.optDouble(1, Double.NaN), a.optDouble(2, Double.NaN))
            }
        }.getOrDefault(emptyMap()).also { locations = it }
    }

    private fun save(known: Map<String, Location>) {
        locations = HashMap(known)
        val o = JSONObject()
        // JSON has no NaN: a photo without a place is stored as its stamp alone.
        for ((k, l) in known) o.put(k, JSONArray().put(l.stamp).apply { if (!l.lat.isNaN()) put(l.lat).put(l.lon) })
        write(locationsFile, o.toString())
    }

    private fun savePlaces(known: Map<String, String>) {
        places = HashMap(known)
        write(placesFile, JSONObject(known).toString())
    }

    private fun write(file: File, text: String) = runCatching {
        dir.mkdirs()
        val tmp = File(dir, file.name + ".tmp")
        tmp.writeText(text)
        tmp.renameTo(file)
    }.onFailure { AppLog.warn("Search index: couldn't save ${file.name}: ${it::class.simpleName}") }

    private fun powerSaving() = app.getSystemService(PowerManager::class.java)?.isPowerSaveMode == true
    private fun charging() = app.getSystemService(BatteryManager::class.java)?.isCharging == true
    private fun online(): Boolean = runCatching {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        cm.getNetworkCapabilities(cm.activeNetwork)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }.getOrDefault(false)

}
