# Third-party notices

Lelvo is licensed under the GNU General Public License v3.0; see [LICENSE](LICENSE). The apps include the
third-party software below, each under its own license. The apps show the same list under
Settings → About → Acknowledgements.

| Software | What it does | License |
|---|---|---|
| [TDLib](https://github.com/tdlib/td) | Telegram's client library: sign-in, uploads, downloads | [Boost Software License 1.0](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt) |
| [TDLibFramework](https://github.com/Swiftgram/TDLibFramework) | TDLib built for Apple platforms | [MIT](https://github.com/Swiftgram/TDLibFramework/blob/main/LICENSE) |
| [TDLibKit](https://github.com/Swiftgram/TDLibKit) | Swift API for TDLib | [MIT](https://github.com/Swiftgram/TDLibKit/blob/main/LICENSE) |
| [OpenSSL](https://www.openssl.org) 3.x | Cryptography inside TDLib | [Apache License 2.0](https://www.openssl.org/source/license.html) |
| [Argon2](https://github.com/P-H-C/phc-winner-argon2) reference implementation | Passphrase key derivation (Argon2id), included unchanged in [Packages/LelvoCore/Sources/CArgon2](Packages/LelvoCore/Sources/CArgon2) | [CC0 1.0 or Apache License 2.0](https://github.com/P-H-C/phc-winner-argon2/blob/master/LICENSE) |

The website ([website/](website/)) uses the fonts [Bricolage Grotesque](https://github.com/ateliertriay/bricolage) and
[Source Serif 4](https://github.com/adobe-fonts/source-serif), both under the [SIL Open Font License 1.1](https://openfontlicense.org).
The App Review demo library in the iPhone app ([iOS/DemoLibrary](iOS/DemoLibrary)) uses sample photos from
[Unsplash](https://unsplash.com/license).

Smooth scrolling uses [Lenis](https://github.com/darkroomengineering/lenis) under the MIT License
([website/vendor/LENIS-LICENSE.txt](website/vendor/LENIS-LICENSE.txt)). Sample photos in the screenshots are from
[Unsplash](https://unsplash.com/license).

Apple frameworks (SwiftUI, UIKit, AppKit, PhotoKit, AVFoundation, CryptoKit, SQLite and others) are part of the
operating system and aren't redistributed.

## Not included

Lelvo doesn't contain code from [AKS-Labs/CloudGallery](https://github.com/AKS-Labs/CloudGallery) or
Whitehole. They inspired the idea; this is a separate implementation written for Apple platforms.
