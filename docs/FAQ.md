# Questions and answers

Plain answers to what people ask before and after trusting CloudGallery with their photos. Where the answer depends
on Telegram, it links to Telegram's own page, because Telegram's rules are Telegram's to set. Last checked against
those pages in October 2026.

- [How it works](#how-it-works)
- [Signing in](#signing-in)
- [Backing up](#backing-up)
- [When something goes wrong in Telegram](#when-something-goes-wrong-in-telegram)
- [Privacy and encryption](#privacy-and-encryption)
- [Storage on your device](#storage-on-your-device)
- [Restoring and new devices](#restoring-and-new-devices)
- [iPhone sideloading](#iphone-sideloading)
- [Mac](#mac)
- [Reporting a problem](#reporting-a-problem)

---

## How it works

**Where are my photos stored?**
In a private channel in your own Telegram account, called "CloudGallery Library" unless you renamed it. Each photo
or video is one file message in that channel, with a short machine-readable caption (date, place, album, size,
checksum). The format is documented in [CLOUD_FORMAT.md](CLOUD_FORMAT.md), so your library isn't tied to this app.

**Does CloudGallery have servers? Does it see my photos?**
No servers, and no. The app talks only to Telegram, as you, the same way the official Telegram apps do. The project
has no way to see your library, your account or anything else.

**Is it allowed by Telegram?**
Yes. Telegram lets third-party apps use its API under the [Telegram API Terms of Service](https://core.telegram.org/api/terms).
CloudGallery follows them: its own `api_id` (§2.1), a clear note that it uses the Telegram API (§2.2), no "Telegram"
in its name (§2.3), no Telegram logo (§2.4), and nothing that changes how Telegram works for other people (§1.4). It
doesn't use your data for anything, including AI training (§1.5).

**Is the storage really unlimited and free?**
Telegram describes its cloud storage as unlimited, with files up to 2 GB each, or 4 GB with Telegram Premium
([Terms of Service](https://telegram.org/tos), [FAQ](https://telegram.org/faq)). That is Telegram's offer, not a
promise CloudGallery can make, and Telegram can change it. Files larger than your limit are split into parts
automatically and joined again on download.

**Why "Not affiliated with Telegram"?**
Because it isn't. CloudGallery is an independent, community project. Telegram doesn't make, review or support it.
Questions about your Telegram account itself go to Telegram; questions about the app come here.

---

## Signing in

**Why does it need my phone number?**
Telegram accounts are identified by phone number. CloudGallery signs in to *your* account, like any Telegram app,
so that files go to your own channel. The number goes only to Telegram.

**The login code doesn't arrive.**
Telegram first sends it as a message to your other Telegram apps (look in the chat named "Telegram"), not by SMS.
If you have no other Telegram app signed in, wait for the option to receive it by SMS or call. Codes are 5 or 6
digits; some numbers get a word or phrase instead, and the code screen adapts to whichever Telegram sends.

**It asks for a password.**
That's your Telegram two-step verification password, the one you set in Telegram → Settings → Privacy and Security.
CloudGallery never sees it after it is sent to Telegram.

**It says the app key was refused and asks for an `api_id` / `api_hash`.**
Telegram decides which apps may connect. If it ever refuses the key built into this copy of the app, you can keep
going with your own free key: log in at [my.telegram.org](https://my.telegram.org), open **API development tools**,
create an app (any name), and paste the two values. Your library isn't affected. Builds from source without keys
always ask for this.

**Does signing in log me out of my other Telegram apps?**
No. CloudGallery is one more session, like Telegram Desktop. You'll see it in Telegram → Settings → Devices.

---

## Backing up

**What gets backed up?**
Photos, videos and Live Photos (both parts), as the original files, plus the edited version of anything you edited in
Photos. You can limit it to photos or videos, skip screenshots, include or exclude albums, or start from a date
(Settings → Backup options).

**Does it back up on its own?**
Only if you switch on **Back up new photos automatically**. Otherwise nothing uploads until you tap **Back up now**
(everything not yet backed up) or **Back up** on photos you picked.

**Why does a big backup need the app open?**
iOS lets apps run in the background only in short, system-controlled windows, and Telegram's connection can't use
iOS's background transfer service. CloudGallery uploads while it's open; on iOS 26 and later, **Back up now**
continues in the background with progress on the Lock Screen; it also runs overnight while charging, and for about
25 seconds per Shortcuts run. Everything is saved as it goes, so each run continues where the last stopped.

**It says "Telegram asked to slow down".**
Telegram limits how fast any account may send. When it asks CloudGallery to wait, the app waits exactly as long as
asked, then continues on its own. That's normal and protects your account. CloudGallery also uploads at most two
files at a time on purpose.

**Some items failed.**
**Backup → Failed** lists every one with the reason and a **Retry** button. Common reasons: no internet, a photo
still downloading from iCloud Photos, or a file removed from the phone mid-upload.

**Does it upload the same photo twice?**
No. Each photo is checked by its Photos identifier and its SHA-256 checksum, so copies are recognised even after a
reinstall or on another device. **Backup → Duplicates** finds anything that was already stored twice and removes only
the extra copies.

---

## When something goes wrong in Telegram

Your backup is only as safe as the Telegram account and channel it lives in. None of the cases below ever delete
photos that are still on your phone: CloudGallery only deletes from your phone when you ask it to, and iOS always
asks you to confirm.

**I deleted the library channel (or Telegram did).**
Every file in it is gone and can't be restored, by CloudGallery or anyone else. When CloudGallery re-scans the library
(Backup → Re-scan, or after a library switch), items that are still on your phone are marked failed with "Not found in the Telegram channel any more" and can be
backed up again with Retry, into a new library. Items that existed only in the channel are lost. This is why
[a second copy](#storage-on-your-device) of what you can't lose matters.

**I deleted some messages in the channel from the Telegram app.**
Those items are no longer backed up. After **Backup → Re-scan**, items still on your phone show as failed and Retry
uploads them again. Please don't edit, forward or delete messages in the library channel by hand.

**I renamed the channel.**
Nothing happens. Libraries are recognised by a pinned header message, not by their name. Don't unpin or delete that
header message.

**My Telegram account was deleted for inactivity.**
Telegram deletes accounts that don't come online for a set time, 18 months by default, and everything in them goes
with them ([Telegram FAQ: account self-destruction](https://telegram.org/faq#q-how-does-account-self-destruction-work)).
A deleted account can't be restored. To prevent it, CloudGallery shows the current setting in Settings → Telegram
and can change it to the maximum Telegram allows, 2 years (730 days). You can also set it in the Telegram app under
Settings → Privacy and Security, in the "delete my account if away for" option. And open the Telegram app now and then.

**I deleted my Telegram account myself.**
Deleting an account "permanently removes all your messages and contacts", and channels you created are left without
an owner ([Telegram FAQ: deleting your account](https://telegram.org/faq#q-how-do-i-delete-my-account)). Treat the
library as gone. Download a copy first (Settings → Download a copy of your library).

**My account is frozen.**
Telegram freezes accounts that were restricted after reports from other users. A frozen account can still read its
chats but can't send messages or post content, and you can appeal in the Telegram app; if the restriction was a
mistake, the account is unfrozen ([Telegram FAQ: frozen accounts](https://telegram.org/faq#q-what-is-a-frozen-account)).
In CloudGallery this means: browsing, viewing and downloading your library keep working, uploads fail with a message
about the frozen account, and backups resume once the account is unfrozen. Retry the failed items afterwards.

**My account is limited ("can only message mutual contacts").**
That's Telegram's anti-spam limit on messaging people who don't have your number. Telegram says to contact
[@SpamBot](https://t.me/SpamBot) if you think it was applied by mistake, and that first limits usually last a few days
([Telegram spam FAQ](https://telegram.org/faq_spam)). If Telegram also stops the account from creating a channel,
CloudGallery says so and suggests using an existing channel or another account.

**My phone number was banned.**
Telegram bans numbers for breaking its [Terms of Service](https://telegram.org/tos). CloudGallery can't sign in to a
banned number. Normal personal backup doesn't cause bans: CloudGallery only posts to your own private channel, paces
its uploads, and does what Telegram asks.

**I ended the CloudGallery session from Telegram → Devices.**
CloudGallery shows the sign-in screen again. Sign in with the same account and your library is still there.

**I changed my phone number in Telegram.**
Telegram lets you change your number and keep everything ([Telegram FAQ](https://telegram.org/faq#q-how-do-i-change-my-phone-number)).
CloudGallery stays signed in; if you sign in again later, use the new number.

**I lost my phone number.**
Telegram sends login codes to your other signed-in Telegram apps first, so keep at least one other device signed in
(Telegram Desktop or a Mac, for example), and set up two-step verification with a recovery email in Telegram.

**Telegram is down or slow.**
Backups wait and continue later; nothing is lost. Items already on your phone stay viewable.

---

## Privacy and encryption

**Can Telegram see my photos?**
In a **Standard** library, files are encrypted in transit and stored on Telegram's servers like any other cloud
chat, but cloud chats are not end-to-end encrypted ([Telegram FAQ](https://telegram.org/faq#q-so-how-do-you-encrypt-data)).
In an **End-to-end encrypted** library, CloudGallery encrypts every file and caption on your device before upload
(AES-256-GCM, key derived from your passphrase with PBKDF2-SHA256 at 600,000 iterations). Telegram then stores only
unreadable `.cge` files. Details: [CLOUD_FORMAT.md](CLOUD_FORMAT.md#6-end-to-end-encryption).

**Can I open my photos in the Telegram app?**
Standard libraries: yes, they're normal files. Encrypted libraries: no, only CloudGallery with your passphrase can.

**I forgot my passphrase.**
It can't be recovered or reset by anyone, including the people who make CloudGallery. That's what end-to-end means.
Without it, the encrypted files can't be opened. Keep it in a password manager.

**Can I switch a library between Standard and Encrypted?**
No, it's chosen when the library is created. You can create a second library of the other kind (Settings → Library →
New library) and back up into that one.

**What does CloudGallery store on my device?**
Your Telegram session (encrypted), app keys and encryption key in the Keychain, a local index of your library, and
capped caches of thumbnails and viewed items. Everything is removed by **Settings → Sign out and reset** or by
deleting the app. See [PRIVACY.md](../PRIVACY.md).

**Are there ads or analytics?**
No ads, no analytics, no crash reporting, no tracking.

---

## Storage on your device

**Does it fill up my phone?**
No. Thumbnails (300 MB) and viewed photos and videos (1 GB) are capped and can be changed or cleared in
Settings → Storage. Clearing never touches your photos or your backup.

**I used Free Up Space but my storage didn't change.**
Removed items go to Photos → Recently Deleted for 30 days. Empty it to get the space back now.

**What does Free Up Space remove?**
Only items that CloudGallery has just checked are completely in your Telegram channel with the right size, and that
weren't edited after their backup. Everything else is never offered. iOS asks you to confirm every deletion.

**How do I keep a second copy?**
Settings → **Download a copy of your library** saves every original (and edit, and Live Photo video) to a folder you
choose: Files, iCloud Drive, a USB drive or SSD, or a Mac folder. It's resumable and skips files already there.

---

## Restoring and new devices

**New phone, or reinstalled the app?**
Install, sign in with the same Telegram account, and choose your library. CloudGallery reads the channel and
rebuilds everything: dates, places, albums, favourites and Live Photo pairs. Photos still on the phone are matched to
their backups, so they aren't uploaded again.

**Several devices, one library?**
Yes. Sign in on each; they all back up into, and show, the same library.

**Several libraries?**
Yes: Settings → Library lists every library in your account. Switch, rename or create one without signing out.

---

## iPhone sideloading

**The app stopped opening after a week.**
Apps signed with a free Apple ID expire after 7 days, as Apple's developer support
[confirms](https://developer.apple.com/forums/thread/92538). SideStore and AltStore refresh it automatically; with
Sideloadly, install the same IPA again. Installing over the old copy keeps your sign-in and data. Even a full reinstall
only means signing in again: the library is in Telegram.

**"Untrusted developer" or "Developer Mode required".**
Settings → General → VPN & Device Management → trust your Apple ID; and Settings → Privacy & Security → Developer
Mode → on, if iOS asks.

**Will it be on the App Store?**
That's the plan. The checklist is in [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md).

---

## Mac

**Does the Mac back up its Photos library?**
Yes, the Photos library on that Mac, into the same Telegram library as your iPhone if you sign in with the same
account. With automatic backup on, it checks every hour while CloudGallery is open, even with its window closed.

**"Apple could not verify CloudGallery".**
Until releases are notarized, right-click the app in Applications → **Open** → **Open**, once.

**Where does it keep its files?**
`~/Library/Application Support/com.shahil-kv.cloudgallery.mac` and `~/Library/Caches/com.shahil-kv.cloudgallery.mac`.

---

## Reporting a problem

Settings → **Logs** → share the log file, and [open a bug report](https://github.com/shahil-kv/CloudGallery/issues/new/choose).
Phone numbers, keys, channel IDs and file IDs are removed from logs before you see them, but read the log before you
post it. Security problems go to [SECURITY.md](../SECURITY.md), never to a public issue.
