# Privacy policy

Effective 3 November 2026. Applies to the Lelvo apps for iPhone, iPad and Mac.

**In one sentence:** Lelvo sends your photos from your device to your own Telegram account and nowhere else;
the people who make it never receive any of your data.

## Who we are

Lelvo is a free, open-source app maintained by [@shahil-kv](https://github.com/shahil-kv) and contributors.
Contact: [support@lelvo.app](mailto:support@lelvo.app), or an issue at
[github.com/shahil-kv/Lelvo](https://github.com/shahil-kv/Lelvo/issues). Security problems: [SECURITY.md](SECURITY.md).

## What we collect

**Nothing.** Lelvo has no servers. It contains no analytics, advertising, tracking or crash-reporting code, and
it doesn't share data with anyone. We can't see who uses the app, your photos, your Telegram account or your library.

**Why the App Store label lists data:** Apple counts anything an app's built-in code sends to another company. Lelvo
uses Telegram's code to reach your account, so the label lists your phone number, photos and videos, and Telegram
user ID. They're used only to run the app, never to track you, and they go only to Telegram. We never receive them.

## The website's waiting list

If you join the waiting list on the website, your email address and the device you chose are stored in a Google
Sheet that only the maintainer can open, with the date you joined. They are used once, to tell you when Lelvo is on
TestFlight and the App Store, and never shared or sold. To be removed, email
[support@lelvo.app](mailto:support@lelvo.app). Google's [privacy policy](https://policies.google.com/privacy)
applies to the Sheet. The apps never collect your email.

## Where your data goes

- **Photos and videos you back up** go directly from your device to a private channel in **your own Telegram
  account**, over Telegram's encrypted connection. Telegram's [privacy policy](https://telegram.org/privacy) applies
  to what is stored there.
- **Your phone number, login code and two-step password** go only to Telegram, to sign you in.
- **End-to-end encrypted libraries:** files and their details are encrypted on your device before upload. Your
  passphrase and the key derived from it never leave your device, and nobody, including us, can recover them.
- **Links you open** from the app (this policy, the FAQ, GitHub) open in your browser, under that site's own policy.

## What stays on your device

- Your Telegram session (in an encrypted database), the Telegram app keys and your encryption key, in the Keychain,
  readable only by Lelvo on this device and never synced.
- A local index of your library (names, dates, sizes, places and Telegram message IDs) so the timeline opens quickly.
  It is excluded from device backups because it can be rebuilt from Telegram.
- Caches of thumbnails and items you viewed, with size limits you control.
- A diagnostic log, which never leaves the device unless you share it yourself. Phone numbers, keys, channel IDs and
  file IDs are removed from it.

**Settings → Sign out and reset** deletes all of this from the device, and so does deleting the app. It doesn't delete
your library in Telegram.

## Keeping and deleting your data

- **On your device:** data stays until you sign out and reset, or delete the app.
- **In Telegram:** your library stays in your channel until you delete it. Telegram keeps it under its own
  [privacy policy](https://telegram.org/privacy), and we can't see or delete it for you. You can delete the channel in
  the Telegram app, or your whole account at [my.telegram.org/delete](https://my.telegram.org/delete).
- **To stop sharing:** signing out ends Lelvo's access to your Telegram account. You can also end the session in
  Telegram under Settings → Devices. Turning off Photos access in iOS or macOS settings stops new backups.

Telegram is the only third party that receives your data, and only because you sign in and choose to back up. We don't
share data with anyone else, so no other company has to protect it.

## Permissions

- **Photos:** to read the photos you choose to back up and to save downloaded ones back. You can allow limited access,
  or none, and still browse your cloud library.
- **Network:** to talk to Telegram.

## Children

Lelvo isn't directed at children under 13, and it doesn't knowingly handle any child's data, because it handles
no one's data.

## Changes

If this policy changes, the new version is published here with a new effective date, and the history is visible in
this repository.
