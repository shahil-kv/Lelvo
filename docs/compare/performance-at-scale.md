# Performance at scale: Ente and Immich vs Lelvo (2026-11-18)

Scope: client-side loading speed and large-library (40k to 100k+ items) behaviour. Read from the clones with grep/sed only.
Not verified: nothing was run or profiled; Ente/Immich behaviour is from reading code (not measuring it); Lelvo "has it" is from grep, so a feature can exist under a name I did not search. GitHub issue search returned no results (rate limit or empty), so the "perf commits/issues" part is not covered. Ente's Rust/ML paths were not read.

## Table

| Technique | Ente | Immich | Lelvo has it? | Impact | Effort | Stored-data change? |
|---|---|---|---|---|---|---|
| Thumbnail sizes | 2 sizes: 256 px and 512 px, JPEG quality 50 (`core/constants.dart`) | Server makes thumbnail + preview (+ thumbhash); client asks per use | One Telegram thumbnail (~320 px, `ThumbnailPipeline`); phone items sized by grid bucket (128 px steps) | low | - | no |
| Placeholder (ThumbHash) | no (loads from local disk) | yes, server computes, ~25 B in the asset row, decoded natively (`ThumbHash.kt`, `LocalImagesImpl.swift`) | Code exists (`Format/ThumbHash.swift`, `ThumbHash.kt`) but nothing draws it; the format has no field for it | high on first open, after cache clear, new device restore | M | Caption field = format change (parked). Local-only variant (hash computed from the first downloaded thumbnail, kept in a local table) = local schema change only |
| In-memory image cache with limits | LRU of 1000 thumbnails (`thumbnail_in_memory_cache.dart`) | Split cache: small images normal, large images max 5 (`custom_image_cache.dart`) | yes: NSCache 150 MB iOS / 400 MB Mac, 3000 items; cloud 120 MB; trimmed on memory warning. Android: Coil defaults | - | - | no |
| Disk cache with eviction | disk cache by size | URLCache | yes: LRU 300 MB thumbs, 1 GB viewed, TDLib optimizeStorage | - | - | no |
| Cancel and de-dup on fast scroll | task ids cancelled when tile unmounts, 10 ms start delay (`thumbnail_widget.dart:111`), per-request `diskLoadDeferDuration` | native decode cancellable mid-decode (`NativeCore.cancel`), request registry | yes on Apple: cancellable tasks, PriorityGate (newest first, prefetch promoted). Android: Coil cancels on dispose only | - | - | no |
| Defer loading during a fling | partial (defer durations) | yes: `recommendDeferredLoading` skips image loads while velocity is high, 100 ms debounce | iOS has `motion.isScrolling` but it only cancels video preload; thumbnails still start during a fling. Android: no | medium | S | no |
| Prefetch ahead of scroll | yes | `scrollCacheExtent` = 2 screens | Apple yes (`prefetchDataSource` + `ThumbnailPipeline.prefetch`). Android: none found | high on Android | S-M | no |
| Decode off main, at display size | yes (cacheWidth/Height) | native ImageIO / Android decoder on a bounded queue (cores x 2) | Apple yes (`byPreparingForDisplay`, `downsampled`). Android: Coil decodes at view size; Lelvo turned off `ImageDecoder` (HEIC), BitmapFactory path not checked for sampling | - | - | no |
| Virtualization / recycling | list with day groups | custom sliver, fixed-height segments | yes: UICollectionView, NSCollectionView, LazyVerticalGrid with `key` and `contentType` | - | - | no |
| Timeline query: buckets + paged assets | whole list in memory, indexed `creation_time` | SQL bucket counts (day/month) with an index on local date day/month, assets paged 1024 at a time, 64 behind (`timeline.service.dart`) | Not paged on Apple: `allItems()` decodes every JSON blob and builds all entries in memory on each full reload; no index on `creation_date`. Android: windowed (`windowStart`) | high at 100k (startup, library switch, full refresh) | M-L | Local index change only (add `creation_date` index, or lite columns), rebuildable cache, not the format |
| SQL indexes | collection, folder, creation, updation, hash, added | many, incl. day and month expression indexes | partial: local_id, sha256, status. Missing creation_date | medium | S | local index only |
| Batched inserts / transactions | `_insertBatch`, write transactions | sync events in batches of 5000, FK pragma off inside the batch | yes: `inWriteTransaction`, WAL, synchronous=NORMAL | - | - | no |
| Incremental sync | by collection update time | server event stream with ack | yes: incremental scan before each backup; patches from PHChange | - | - | no |
| Startup deferred | partial | yes | yes: snapshot restore 0.13 s, background re-scan, PhotoAvailability probe | - | - | no |
| Memory pressure | none found | cache limits | iOS and Mac yes (`trimMemory`); Android relies on Coil | low | S | no |
| Video preview preload | n/a in grid | n/a in grid | yes: `VisibleVideoPreloader`, neighbour prefetch, off on metered network | - | - | no |
| Background throttling | - | - | yes: 2 lanes, FLOOD_WAIT, 1.5 s reload spacing; Low Power read in a few places, thermal state only logged | low | S | no |
| Benchmark / profiling tooling | `integration_test` | e2e only | yes: `-autoScrollTest`, Mac `scrolltest`, XCTOSSignpost scroll metric. No Android benchmark (no Macrobenchmark) | medium | M | no |
| `PRAGMA optimize` / ANALYZE | no | logger DB only | not found | low-medium after indexes added | S | no |

## Do before many users

1. Android: scroll-aware loading (pause new thumbnail loads while a fling is fast) and a small prefetch window, so a 40k timeline fling does not queue hundreds of Telegram reads. Needs a before/after frame-time run on the emulator (no Macrobenchmark yet).
2. Apple and Android: stop decoding the entire library on every full reload. First step, cheapest: add `CREATE INDEX idx_items_date ON items(creation_date)` and run `PRAGMA optimize` after migrations. Second step: keep id, date, kind, status in real columns so the timeline does not decode JSON for items off screen.
3. ThumbHash placeholder from a local-only table (no caption change): hash computed after the first thumbnail download, drawn before the real image. Do not touch the caption format.
4. iOS/Mac: use `motion.isScrolling` to hold back non-urgent thumbnail starts during a fling (Immich's deferred loading).
5. Android Macrobenchmark scroll test on a 40k demo library, to match the Apple benchmarks.
6. Android: confirm Coil memory cache size and that `ImageDecoder` off still downsamples (not verified).

## Skip because it is server-side

- Server thumbnail/preview generation, transcoding queues, job queues (BullMQ), Postgres tuning, read replicas, CDN and image proxy caching, Redis.
- Server-computed ThumbHash and bucket counts (Lelvo has no server; the local-only variant above replaces it).
- Per-user rate limiting and storage sharding: Telegram limits are per account.
- ML (faces, CLIP) pipelines and their batching.
