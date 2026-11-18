# Gallery timeline, grid, scroll, thumbnails, selection, scrubber: Lelvo vs Ente vs Immich

Date: 2026-11-18. Read-only comparison. Caveat: GitHub search API was rate-limited (30/hr) after the first round, so issue mining is thin (see "Unverified"). Findings below come mostly from code.

## How Ente does it
Flutter, one sectioned sliver list (`ui/viewer/gallery/component/sectioned_sliver_list.dart`, `gallery.dart` 1648 lines) with a debounced reload (`gallery.dart:156,215`). Pinch is a custom zoom layer that precomputes a layout for every column count (`gallery_grid_zoom.dart:112-125`, `photoGridSizeMin..Max`). Swipe-to-select (`swipe_to_select_helper.dart`) selects a range from an anchor, fires `HapticFeedback.selectionClick` on each change (lines 33-123), and can deselect when the anchor was already selected. The scrollbar (`scrollbar/custom_scroll_bar.dart:46-132`) draws year labels along the track ("scrollbar divisions", `models/gallery/gallery_groups.dart:137,779`), only when the list is longer than 8 viewports. Separate `jump_to_date_gallery.dart` gives a date picker jump. Thumbnail snapshot widget keeps a frame during zoom (`gallery_thumbnail_snapshot.dart`).

## How Immich does it
Flutter, bucketed timeline (`presentation/widgets/timeline/`): `segment.model.dart` and `segment_builder.dart` lay out month buckets from server counts, so scroll extent is known before any asset loads. `sliver_segmented_list.dart:181` computes its own cache extent. Scrubber (`scrubber.widget.dart`, 577 lines): month segments, year labels only when `lastOffset + threshold <= startOffset` and year changed (line 37), thumb fades out after 800 ms (`constants.dart`), `selectionClick` haptic on each month change (line 219), snap-to-month option. Drag-select (`timeline_drag_region.dart`): long press, then a 50 ms periodic timer auto-scrolls when the finger is outside a top/bottom band (lines 120-160). Pinch maps scale to 1-5 columns (`timeline_pinch_zoom.dart:50`). Thumbnails: ThumbHash placeholder while loading (`images/thumbnail.widget.dart:18-75`, `thumb_hash_provider.dart`); load requests are cancellable and per-load state prevents a cancelled load affecting the next (`images/image_provider.dart:16-150`). Known scrubber bugs fixed or filed: misaligned/off-by-one month label (immich #19380, #20137), year markers hard to read (#22966), scrubber stalls on a 2M library (#31358), hang when scrolling into a huge month bucket (#28861), scrubber unusable on search page (#21762), popup covers the scrubber date (#26920). Only #19380 body was readable here; others unread.

## How Lelvo does it
- iOS: `UICollectionView` with diffable data source, recycled cells, prefetch data source (`iOS/Views/Gallery/NativePhotoGrid.swift:26-45`), custom `PinchGridLayout` where the tile under the fingers stays put (lines 403-490), day/month regrouping after pinch with top-tile anchoring (149-160), pinch never counts as tap (246-262), swipe-to-select with a `CADisplayLink` edge auto-scroll that waits for real movement (294-380) and `Haptics.selection()` (270, 351, 450), scrub thumb uses the same fraction the thumb shows (235), VoiceOver label and selected trait per cell (792-793), header trait and "n items" (835-844), Dynamic Type header font (842).
- Thumbnails: `Shared/Support/ThumbnailPipeline.swift` NSCache (3000 items, 150 MB iOS / 400 MB Mac, lines 24-36), 128 px size buckets so zoom doesn't reload (39), low-res then sharp stream (53), `prefetch` / `cancelPrefetch` (100,121), cell `prepareForReuse` cancels its task (`NativePhotoGrid.swift:721-723`), memory warning clears cache (`iOS/App/LelvoApp.swift:16-19`). There is a `ScrollBenchmark.swift` in `iOS/Views/Gallery/`.
- Mac: `NSCollectionView` + prefetching (`macOS/Views/MacPhotoGrid.swift:53,271-278`), keyboard (arrows, Space, Esc, Delete, Cmd-A, 396-414), trackpad pinch (427), click with modifiers (649).
- Android: Compose `LazyVerticalGrid` with stable keys and content types (`android/.../timeline/TimelineScreen.kt:533-553`), pinch steps combining columns and day/month grouping (108-125, 633), `dragToSelect` with edge auto-scroll (`Selection.kt:59-148`), `DateScrubber.kt` with fraction over the whole library, `SegmentTick` haptic (110), semantics description per cell (`TimelineScreen.kt:596`), Coil image loader (`LelvoApp.kt:245`).

## Table

| Case / feature | Ente | Immich | Lelvo has it? | Verdict | Effort | Platforms |
|---|---|---|---|---|---|---|
| Native recycled grid, 60 fps path | Flutter sliver | Flutter sliver | Yes, UICollectionView / NSCollectionView / LazyGrid | ALREADY BETTER on Apple | - | - |
| Thumbnail memory cache + size buckets | yes | yes | Yes (`ThumbnailPipeline.swift:24-39`) | ALREADY BETTER | - | iOS, Mac |
| Cancel in-flight loads on reuse/scroll-away | partial | yes (`image_provider.dart:137`) | Yes iOS/Mac; Android relies on Coil/Compose | SKIP | - | - |
| Placeholder while thumbnail loads (ThumbHash) | n/a (e2e, loads from disk) | ThumbHash from server (`thumbnail.widget.dart:18`) | No. Cloud-only tiles show flat colour until Telegram thumb arrives. grep thumbhash finds none in UI | ADOPT: compute a tiny blur (ThumbHash/BlurHash) at backup, store in caption JSON | L (format change, needs approved issue + version bump) | all |
| Month/year scrubber labels along the track | yes, years, only >8 viewports (`custom_scroll_bar.dart:74`) | yes, year-dedupe rule (`scrubber.widget.dart:37`) | Thumb shows date while dragging; no always-visible year ticks found | ADOPT year ticks with min-spacing rule | M | iOS, Mac, Android |
| Scrubber haptic per month change | yes | yes (`:219`) | Android yes (`DateScrubber.kt:110`); iOS not confirmed in scrub code | ADOPT check | S | iOS |
| Scrubber fades out after idle (800 ms) | no | yes | Unverified | ADOPT if missing | S | all |
| Scrub position correct on huge libraries | n/a | bugs #31358, #19380 | Fraction-based (`NativePhotoGrid.swift:235`) | Verify at 40k: label vs landing month | S | all |
| Jump to date picker | yes (`jump_to_date_gallery.dart`) | partial (search by date) | No jump-to-date UI found (only a filter DatePicker in Settings) | ADOPT | M | all |
| Pinch zoom levels | custom layout per column count | 1-5 columns | Yes, plus day/month/year regrouping, anchor keeps tile under fingers | ALREADY BETTER | - | - |
| Drag-select with edge auto-scroll | yes (swipe helper) | yes, 50 ms timer | Yes, display-link/gesture driven | ALREADY BETTER | - | - |
| Haptic on each selection change | yes (many calls) | partial | Yes iOS (`Haptics.selection`); Android only on long press start (`TimelineScreen.kt:541`) | ADOPT per-tile tick on Android | S | Android |
| Drag-select cost on 40k items | O(n) `indexOf` | n/a | Android `Selection.kt:104-112,119-124` calls `order().indexOf(key)` and builds a Set on every move: O(n) per event | ADOPT (index map / lazy range) | S | Android |
| Mac marquee (rubber-band) and shift-click range select | n/a (mobile) | web only | Click modifiers exist (`MacPhotoGrid.swift:649`); no drag marquee found | ADOPT verify, add if missing | M | Mac |
| Keyboard navigation on Mac | n/a | web | Yes | ALREADY BETTER | - | Mac |
| Empty / loading / no-access states | yes | yes | Yes (`GalleryView.swift:52-76,243-261`) | SKIP | - | - |
| Memory pressure handling | partial | partial | iOS yes (`LelvoApp.swift:16`); Mac not found; Android relies on Coil | ADOPT Mac trim hook | S | Mac |
| VoiceOver / TalkBack per tile, headings | partial | partial | Yes (iOS 792-844, Android 596, 550) | ALREADY BETTER | - | - |
| Dynamic Type headers | n/a | n/a | Yes (`NativePhotoGrid.swift:842`) | ALREADY BETTER | - | iOS |
| Known layout extent before assets load (bucket counts) | no | yes, server counts | Sections from local index; Android loads windowed (`windowStart`) | Verify scroll extent stable | M | Android |
| Zoom snapshot to avoid flash while re-laying out | yes (`gallery_thumbnail_snapshot.dart`) | no | iOS settle link; Android recomposes | Verify Android pinch flicker | M | Android |

## Unverified
- Issue mining: only Immich #19380 body read. Ente search returned nothing before rate limit; no Ente issue evidence.
- iOS scrub thumb: idle fade-out and per-month haptic not confirmed (grep only hit `Haptics.selection` at lines 270/351/450).
- Mac drag/marquee selection and Mac memory-pressure handling: absence inferred from grep, not from full read.
- Android prefetch beyond Compose's built-in one-row lookahead; Coil cache sizes not read.
- No device 60 fps measurement made; `ScrollBenchmark.swift` exists but was not run.
