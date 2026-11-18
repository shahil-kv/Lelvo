# Viewer, video playback, Live Photos, viewed-media cache: Lelvo vs Ente vs Immich

Date: 2026-11-18. Read-only comparison. Ente and Immich checked in local clones (paths under `mobile/`); issue mining was limited:
Ente's tracker is not searchable with `gh` (search returned "invalid query", issues appear disabled), and the GitHub search rate limit
(30/min) was hit, so only Immich issues were opened (#14758, #15014, #15362, #24770, #31475). Most were low signal (server transcode / thumbnail bugs).

## How Ente does it

- Two native paths, with automatic fallback. The native player (`video_widget_native.dart`) is primary; on a playback error it fires `UseMediaKitForVideo` and switches to the media_kit player (`:680-691`).
- Progressive playback of originals: `module/download/progressive_video_stream.dart:22` downloads and decrypts chunks in an isolate and serves them through a local `HttpServer` with Range support (`:370-400`). Seeking beyond the downloaded part has to wait for the download. `_loadProgressively` (`video_widget_native.dart:760`) falls back to a full download if the stream cannot open.
- Preview "streaming" videos: `services/video_preview_service.dart` transcodes on the device with ffmpeg to an encrypted HLS 720p H.264 (`:542-584`, with HDR tone mapping via zscale `:550-552`), uploaded with the file, queued and retried on network errors (`:786-797`), 50 MB cache cap (`:59`). Playing the preview is opt-in/queued, not automatic for every video.
- Viewer chrome: filmstrip pager (`file_viewer_filmstrip*.dart`), hero transition, speed sheet (`video_control/video_speed_bottom_sheet.dart`), mute, double-tap seek (`video_double_tap_seek.dart`), panorama viewer, QR/OCR overlays, EXIF dialogs, download progress ring on video (`video_download_progress_indicator.dart`), wake lock on playback.
- Live photos: `zoomable_live_image_new.dart` plays motion on long press; handles motion photos that lack the live-photo file type (`:279`) and the local-vs-remote video fetch case (`:315`).

## How Immich does it

- Server-centred. The app plays `/assets/{id}/video/playback` (server-transcoded) or `/original` per a "load original video" setting (`presentation/widgets/asset_viewer/video_viewer.widget.dart:163-170`); local file is preferred when the asset exists on the phone (`:150`). Uses a forked `native_video_player` (AVPlayer / ExoPlayer) with HDR support; loop video setting (`:288`), no loop for motion photos.
- Image path: thumbhash placeholder, then thumbnail, then preview, then full (`widgets/images/*`, `ios/Runner/Images`, `android/.../images/RawOrientation.kt`), neighbour preload with a 400 ms debounce (`asset_preloader.dart:20-33`).
- Drag intent classifier for swipe-down dismiss vs scroll (`asset_page.widget.dart:30,167-208`), long press for motion photos (`:392`), OCR overlay, rating bar, stacks.
- Bugs seen: swiping to a motion/live photo broke motion playback after the HDR player landed (#14758, fixed in app 2.7.5); HEVC 10-bit and HDR videos crashed or buffered forever on Android (#15014, #15362); HDR 4K web video dark overlay (#24770 tone-map setting); iPhone Live Photo HEVC MOVs failing server thumbnails (#31475).

## How Lelvo does it

- Streaming: `MediaReader.swift:66-115` maps plaintext range to CGFE chunks to split parts to TDLib ranged reads; `StreamingAsset.swift:8` is an `AVAssetResourceLoaderDelegate` (small pieces, first frame fast, moov-at-end MOVs handled by `MovieLayout.trailingIndexRange` in `prefetch` `MediaReader.swift:197-208`). Seek is instant because only the needed range is fetched. Android twin: `media/CloudDataSource.kt:29-77` (ExoPlayer `BaseDataSource`).
- Quality: stored fast version (`sp`) vs original, chosen from measured throughput per network (`StreamingAsset.swift:159-190`), automatic fallback to the fast version after a stall (`CloudVideo.swift:182-200`), manual menu (`CloudVideo.swift:203`), "make fast version" on demand (`:89`). Android: `VideoPlayer.kt:146-296`, plus `VideoDecoders.canPlay` check and decoder fallback (`media/VideoDecoders.kt:20-40`).
- Preload: `NeighbourPrefetcher` fetches the first 2 MB plus the trailing moov of neighbour videos only when the current one has 15 s buffered (`CloudVideo.swift:335-380`); grid `VisibleVideoPreloader` (`:404`). Only the current page owns a player (`ViewerView.swift:543`). Closing stops TDLib downloads (`MediaReader.swift:228-247`).
- Photos: progressive thumbnail, screen copy (`d`), screen-size decode, then 4800 px detail on zoom (`ViewerView.swift:536-567, 636-650`). Live Photos: still first, then `PHLivePhoto` from original still + paired video (`:573-585`, `:684`). Android `LivePhoto.kt:61-145` also covers Motion Photos.
- Robustness: restart after media-services reset -11819 (`ViewerView.swift:574`), position memory (`:619`), swipe-down dismiss stops sound immediately (`:1282-1312`), AirPlay (`:1019`), frame-strip scrubbing, skip feedback, speed, mute, Mac PiP, share/copy/save/delete with transfer banner, info sheet with HDR/Dolby Vision row (`:887`), failure timing logs (`:1315-1340`).
- Cache: user cap picker 1 GB default and "Clear caches" (`SettingsView.swift:799-833`), decrypted chunk cache dropped when the last player closes (`MediaReader.swift:230`), `enforceCacheLimits`.

## Table

| Case / feature | Ente | Immich | Lelvo has it? | Verdict | Effort | Platforms |
|---|---|---|---|---|---|---|
| Ranged streaming of original, instant seek | download-ahead via local HTTP proxy, seek waits | server HTTP range | Yes, better (chunk decrypt, moov tail prefetch) | ALREADY BETTER | - | all |
| Lower-bitrate fast copy | on-device HLS 720p, opt-in | server transcode | Yes (`sp`, auto by throughput, stall fallback) | ALREADY BETTER | - | all |
| Neighbour preload without stealing bandwidth | no | image preload only | Yes (`NeighbourPrefetcher`) | ALREADY BETTER | - | iOS, Android |
| Player error falls back to second engine | native then media_kit | no | iOS: only -11819 restart, no engine fallback; Android decoder fallback yes | ADOPT (iOS: on `.failed` try fast version or software path) | M | iOS, Mac |
| Retry button on error/unavailable state | download dialogs | error then back | No: `ViewerView.swift:466-470` text only, Android `ViewerNotice` text only | ADOPT | S | all 3 |
| Loop video setting | no | `loopVideo` pref | No (not found) | ADOPT | S | all 3 |
| Keep screen on while playing | wake lock | native player | iOS AVPlayer does by default; Android not found in viewer | ADOPT (verify Android) | S | Android |
| Swipe-down dismiss | yes | drag-intent classifier | Yes | ALREADY BETTER | - | all |
| Live Photo long-press motion | yes | yes (long press) | Yes, plus LIVE chip | ALREADY BETTER | - | all |
| Motion Photo without live type | yes (`:279`) | stack/motion | Android yes | ALREADY BETTER | - | Android |
| Swipe onto Live Photo keeps motion working | ok | regression #14758 | Android `current` flag; iOS `PHLivePhotoView` per page | verify only | S | iOS, Android |
| HDR video display | tone-maps in preview | native HDR player | iOS native HDR; Android no `colorMode` request found | ADOPT (verify on HDR clip) | S | Android |
| HEVC / unsupported codec handling | falls back to preview HLS | transcode | Android `canPlay` + fast copy; iOS HEVC fine | ALREADY BETTER | - | all |
| Placeholder before download (thumbhash) | yes | yes | Real thumbnail `t`; blank after cache clear | SKIP (format change) | L | - |
| Progress ring while video downloads | yes | spinner on buffering | Spinner only | ADOPT (low) | S | all 3 |
| Viewer filmstrip | yes | no | No | SKIP | M | - |
| Panorama viewer | yes | no | No | SKIP (later) | M | iOS, Android |
| OCR / QR / Live Text overlay | yes | OCR | No | SKIP for now (Pro/later) | M | iOS, Android |
| Hero open/close transition | yes | partial | iOS yes (UIKit present), Android shared-element not found | ADOPT (low, verify) | M | Android |
| Cache cap and clear | 50 MB preview cap | native image cache | Yes, user picker | ALREADY BETTER | - | all |
| Zoom to 4800 px detail | yes | full-size step | Yes | ALREADY BETTER | - | all |
| Download progress on share/save | yes | partial | Yes (transfer banner) | ALREADY BETTER | - | all |
| Mute / speed / skip / scrub | yes | yes | Yes | ALREADY BETTER | - | all |

## Unverified

- Android wake lock and HDR `colorMode` (grep found nothing; not run on device).
- iOS behaviour on an AVPlayer `.failed` that is not -11819 (only a log is written, `ViewerView.swift:1330`); user sees black or the thumbnail.
- Ente issue history (tracker unreachable); Immich fixes read only from five issues.
