# What Lelvo won't do

Some requests get a "no" on purpose. This page lists those decisions, so you know before you ask. Requests for
these are closed as *not planned*; if you think a decision is wrong, open a
[discussion](https://github.com/shahil-kv/Lelvo/discussions) with your reasons rather than an issue.

## The principles behind the no's

- **Your data, your account.** Lelvo talks to your Telegram account and nothing else. No servers of ours, no
  accounts of ours, no analytics, no ads.
- **Be a good Telegram citizen.** Everything stays within the [Telegram API terms](https://core.telegram.org/api/terms)
  and normal personal use. Anything that could get an account limited is out.
- **Feel like an Apple app.** Native SwiftUI, UIKit and AppKit, following Apple's own apps.
- **Safe by default.** Nothing is deleted from a device unless the user asks and the system confirms.

## Not planned

- **Android, Windows, Linux or a web version.** The project focuses on making the Apple apps excellent. The storage
  format is documented ([CLOUD_FORMAT.md](CLOUD_FORMAT.md)), so others are free to build compatible apps.
- **A Lelvo server, sync service or account.** It would mean holding people's data.
- **Analytics, crash reporting services or ads**, including "anonymous" ones.
- **Backing up to Google Drive, iCloud Drive, Dropbox, S3 and the like.** Lelvo is about Telegram storage;
  Settings → Download a copy already exports everything to any folder or drive.
- **Spreading one library across several Telegram accounts**, rotating accounts, or anything else that works around
  Telegram's per-account limits.
- **Bot API or "use my bot token" mode.** It limits uploads to 50 MB and downloads to 20 MB; the app signs in as your
  account instead.
- **Faster uploads by ignoring Telegram's slow-down requests** or raising parallel uploads. The pace protects your
  account.
- **Sharing, public albums or links for other people.** Your library is a private channel; share single items with the
  share sheet instead.
- **Face recognition, tagging or AI features that send photos to a server.**
- **Deleting photos from the device automatically**, without the user choosing it each time.
- **Changing a library between Standard and Encrypted after creation.** Create a new library of the other kind
  instead.

## Maybe later

These aren't refused, just not soon: smaller streaming copies for very large videos, an iPad-specific layout, and
importing uploads from the first 1.0 version (Bot API, released as CloudGallery).
