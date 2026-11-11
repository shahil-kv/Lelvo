# Changelog

What's new in Lelvo for iPhone and Mac, newest first. Downloads for each version are on
[GitHub Releases](https://github.com/shahil-kv/Lelvo/releases).

## Unreleased

- **Videos stop when you close them:** the sound stops the moment you tap ✕ or start a swipe down, like Photos. A
  swipe you let go keeps playing, nothing plays after the viewer has closed, and music a video paused comes back.
- **Signing in:** the code screen shows where your code went. When Telegram sends it to the Telegram app, a short
  picture of the Telegram chat says so, and **Open** takes you straight to that chat. SMS codes say "Check your
  messages". If nothing arrives, **Didn't get it?** asks Telegram to send it by SMS or call once its wait is over.
- **Favorites:** a small heart marks favorite photos and videos in every grid, like Photos, on iPhone and Mac. It
  follows hearts set in Lelvo and in Apple Photos.
- **Mac:** the app is now signed and notarized by Apple, so it opens straight away. No more trip to Privacy &
  Security on first launch.
- **New look:** a new logo, a camel whose neck flows into a cloud, and a new violet across the app, the app icon
  (with dark and tinted versions on iPhone) and the website.
- **Opening:** a cold launch zooms through the logo into your library in under a second. Coming back from another
  app shows nothing, and a tap skips it.
- **Backing up:** each photo flies into the logo's cloud the moment Telegram confirms it, the counts roll instead of
  jumping, and a check appears when everything is safe.
- **Free up space:** after you confirm, the photos fly into the cloud and the space freed counts up on the page,
  instead of an alert. Cancelling iOS's prompt no longer shows an error.
- **End of setup:** once your first photo is safe, a short animation pulls your recent photos into the logo.
- **Report a problem** and **Suggest a feature** now open an email to the developer instead of Telegram, with the
  address to copy if no mail app is set up.
- **Smoother and calmer:** haptics arrive with the touch and only for results and picks, messages at the bottom
  never block the buttons under them, a library that takes a moment to load shows its grid instead of a spinner, and
  decorative motion rests in Low Power Mode and with Reduce Motion.
- **Selecting photos on iPhone, like Photos:** once you pick something, the tabs make way for three floating
  buttons: Share, Back Up in violet, and Delete. Tap the count at the top to see only what you picked. Select All,
  Add to Album, Save and Favorite are in the ••• menu with their names. Delete asks in words whether to remove items
  from this iPhone, delete them from the backup only, or delete them everywhere, and says first if any aren't backed
  up yet.
- **Albums and Favorites, in beta:** add photos to an album or make a new one, and favorite them, on iPhone and Mac,
  including photos only in your Telegram library. Every device shows the same albums and favorites, and saving a
  photo to Photos puts it in its albums and Favorites there.
- **Favorites match Apple Photos:** a favorite you add or remove on one device now changes in Apple Photos on your
  other devices too, and a heart you tap in the Photos app reaches your other devices. Changes arrive in about 15
  seconds instead of up to a minute. Re-scan the Telegram library also checks favorites and tidies up.
- **Photos behind the tab bar (iPhone):** like Photos, your photos now run behind the glass tab bar, with no black
  strip under it.
- **Fixed:** messages shown while Settings was open on iPhone were hidden behind it.
- **New web address:** the website is now [lelvo.app](https://lelvo.app), with a new About page.
- **Removed from backup:** photos you deleted from your backup but kept on your iPhone or Mac now have their own row
  on the Backup page. Back them up from there whenever you like. They never upload again on their own.
- **Stop a download:** the × on a video or photo download now stops it straight away, and Share shows progress on
  iPhone, so you can see it working instead of tapping again. On Mac, Share, Export and Save to Photos show progress
  with a stop button.
- **Better search:** searching "beach" also finds shore, ocean, sand and coast, and other common words work the same
  way. On Mac, the Search page has a new design, and letters are no longer lost while the results appear.
- **Clearer Similar:** the button now says "Select extras to delete", and photos that will be deleted show a red
  trash icon.
- **Backup page (iPhone):** Duplicates now has one button, in Collections, and Retry says what it did.
- **Memories:** Pause now responds to a tap, and a photo that can't load says so and moves on.
- **Large libraries:** big photo grids now update without holding up the screen, and temporary share copies are
  cleaned up after a day.
- **Mac grid:** photos sit evenly when scroll bars are always shown, and VoiceOver can now read each photo.

- **Picture in Picture removed:** videos now stop when you leave Lelvo. AirPlay and playback speed stay.
- **Keep a second copy (Mac):** pick a folder on an external drive, a NAS or your Mac once, and Lelvo keeps your
  whole library there, up to date, in Year/Month folders. Nothing is ever deleted from it, and an unplugged drive
  just pauses until you connect it again.
- **New icon:** a sunset photo folded into an L, with a padlock for your private library.
- **Recently Deleted on all your devices:** delete a photo from your backup on your Mac or iPhone, and it moves to
  Recently Deleted on your other devices too, with the same days left. Recover it from any of them. A photo still
  in Apple Photos stays there, and Lelvo doesn't upload it again unless you tap Back up.
- **Swipe to select, like Photos (iPhone):** in Select mode, swipe sideways across your photos to select everything
  between, across rows. Hold near the top or bottom edge to keep scrolling. Starting on a selected photo deselects.

## 0.2.0, 2026-10-31

- **New name: Lelvo** (was Memvo, and CloudGallery before that), with new bundle IDs, so it installs as a new app:
  sign in once and your library comes back. Existing libraries in Telegram keep working unchanged.
- **Report a problem or suggest a feature** from Settings. Lelvo opens Telegram or GitHub with your message ready
  and adds what the app runs on; nothing is sent until you press send.
- **Backups that don't get stuck:** photos you delete from your phone while they wait in the queue are dropped, an
  upload that stops moving for 3 minutes is retried, and photos go before videos. Each upload shows about how long
  is left.
- **Sign out and reset** shows the welcome screen at once, instead of leaving Settings on screen for a few seconds.
- **Own repository.** Lelvo is now a standalone, community-driven project under the GPL-3.0, with a
  contributor agreement, issue forms, an `approved`-issue rule for pull requests, CI on every pull request and
  automated reviews. The iOS and Mac apps live side by side (`iOS/`, `macOS/`, `Shared/`).
- **Sign-in:** login codes of any length (Telegram sends 5 or 6 digits) and codes sent as a word or phrase.
- **Telegram account problems** are explained plainly: frozen accounts, and limits on creating channels.
- **About** shows the source code, license, privacy policy, help and the licenses of included libraries.
- **Privacy manifests** for both apps (no tracking, no data collected).
- Release builds no longer contain the test switches used by UI tests.
- **Sign-in starts at your phone number** in every build; a build without Telegram app keys asks for them after.
- **iPhone only** for now (it still runs on iPad in iPhone mode), and a **demo library** for App Review that never
  connects to Telegram.
- New website pages: [changelog](https://lelvo.app/changelog) and
  [privacy policy](https://lelvo.app/privacy).
- **Fast cloud videos:** each video you back up also gets a small fast version (about a tenth of the size), so it
  plays at once from your Telegram library. The quality button in the viewer switches to the original at any time,
  and older videos can get one with Make Fast Version. Cloud videos seek instantly, keep playing when you switch
  between Wi-Fi and mobile data, and the videos on screen and the photos next to the one you're viewing are fetched
  ahead so they open at once.
- **Saving a cloud video** shows its progress and can be cancelled.
- **Recently Deleted for your backup:** deleting from the cloud keeps the item for 30 days, so you can recover it.
- Versions restart at **0.1.0** for both apps in this repository, released with a one-button Release workflow. Compiler warnings fixed on both platforms.
- **Backups keep everything Photos keeps**, and **Save to Photos puts photos back as they were:** the original with
  its edit (Revert in Photos still works), the RAW of RAW + JPEG photos, Live Photos, favourites, hidden photos and
  the same albums. Photos backed up earlier get the missing pieces from your iPhone or Mac at the next backup.
- **Include hidden photos** in the backup (off by default). Lelvo never shows them, and they come back hidden.
- **Share Original** (touch and hold Share on iPhone) and **Export Unmodified Original** on the Mac.
- **Save all to Photos** (Backup → Tools): everything that's only in your Telegram library back to Photos in one go,
  with a space check first, progress and Stop. If it stops, run it again and it continues.
- **Your library comes back faster on a new device:** Lelvo keeps a compact index of your library in your Telegram
  library, so a new iPhone or Mac shows everything after reading only the latest changes, then checks the rest in the
  background.
- **Change your passphrase, and a recovery key** for encrypted libraries: if you forget the passphrase, the recovery
  key opens your library. Libraries created before get one in Settings → Libraries → Add a recovery key; your photos in
  Telegram stay exactly as they are.
- **Big photos open at once from the cloud:** RAW photos and photos over 3 MB get a small screen copy when backed up,
  shown immediately while the original loads when you zoom in. Photos backed up earlier get one gradually, from files
  already on your iPhone or Mac. Sharing, saving and exporting always use the original.
- **Smoother timeline during a backup** in large libraries: only the photos that changed are updated, instead of
  the whole library being read again every second or two.
- **Your other device's changes show at once:** while Lelvo is open, photos backed up or deleted on your iPhone or Mac
  appear on the other one within seconds, instead of at the next scan.
- **Faster, lighter backups:** new photos are found from Photos' list of changes instead of reading the whole library
  each time, a photo is no longer exported and checked again when its upload is retried, and big videos in an
  end-to-end encrypted library no longer need a full encrypted copy on disk. When space runs out, the item says how
  much to free up.
- **Fixed:** resuming an interrupted upload of a very large video in an end-to-end encrypted library could store a copy
  that couldn't be opened. Such uploads now start that file again.
- **Smoother cloud videos** with less battery: playback waits for Telegram's progress instead of asking every 40 ms,
  and encrypted videos decrypt each piece once.
- **Four tabs, like Google Photos:** Photos, Collections, Search and Backup. Settings opens from the gear at the top of
  every tab.
- **Collections:** Memories (trips included), recent days, albums (Favorites and Screenshots first, then WhatsApp, Instagram and
  your other albums), a map of your photos, media types, documents and receipts, and duplicates. Each shows the first
  few; Show More opens the rest.
- **Memories,** made on your iPhone or Mac: years ago on this day, recent highlights, trips with their place names, and
  themes like pets, beaches and food. Play one like a story; swipe down to close.
- **Search** for places, months, text in photos and things in them, all on your device. Your recent searches come first.
- **Map** of every photo and video with a location, phone and cloud alike.
- **Similar photos** in Duplicates: bursts and near-identical shots grouped, with the best one marked.
- **Video viewer:** double-tap a side to skip 10 seconds, see frames while you scrub, and long videos continue where you
  stopped.
- **Big videos on a full phone:** before backing up, Lelvo checks there's room for the copy it uploads, and tells you
  how much space to free instead of failing with an unclear error.
- **New first run:** a short intro that shows what Lelvo does with real app screens, who can see your photos,
  straight answers to the questions people ask before trusting a backup app, and your own library in numbers.
  A new library gets a name for you, and you only choose Standard or end-to-end encrypted, with a preview of what
  Telegram stores. Then you pick your first photo and watch it arrive. Returning users get a welcome back with their
  library count.
- **Encrypted backups pick up where they stopped:** if a big video's upload is interrupted (the app closes or the
  connection drops), it continues from the next part instead of starting the whole file over.

## Before this repository

Released from the earlier fork, under the name CloudGallery, as iOS 1.0.0 and 2.0.0 betas. If you installed one of those, delete it and install
0.1.0; your library comes back when you sign in.

### 2.0.0-beta.1 (iOS), 2026-10-23
- **Telegram user account via TDLib** replaces the Bot API: no 50 MB / 20 MB limits; files over 2 GB (4 GB Premium) are split automatically.
- **Cloud format 1** (docs/CLOUD_FORMAT.md): one document per resource with versioned caption JSON; restore by scanning channel history (no index file).
- Persistent upload queue with verification, FLOOD_WAIT handling, 2 concurrent uploads, failed-items screen with Retry.
- Streaming video playback with instant seeking, PiP, AirPlay and playback speed; prefetching of adjacent videos.
- Optional end-to-end encryption chosen at library creation (PBKDF2 600k, chunked AES-GCM, encrypted captions).
- Albums tab, year/month/day timeline, date scrubber, drag-to-select, delete from iPhone, codec/HDR info.
- Selection filters: photos/videos only, date range, charging only; capped caches with TDLib storage optimizer.
- UI smoke tests; cross-platform test vectors.
- Docs: issues analysis, architecture, cloud format.

### 1.0.0 (iOS), 2026-10-23
- First native iOS app (SwiftUI) using the Telegram Bot API: original-quality backup, Live Photos, SHA-256 de-duplication, background `URLSession` uploads, an encrypted pinned index for restore, optional E2E encryption, gallery and viewer, Free Up Space (off by default), and Shortcuts actions.
- CI builds an unsigned IPA with Xcode 26.6 and Xcode 27.1.
