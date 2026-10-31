import Foundation

/// Web pages the app links to (About, Settings, error screens). One place to change if the repository moves.
enum AppLinks {
    static let repository = URL.literal("https://github.com/shahil-kv/Memvo")
    static let faq = URL.literal("https://github.com/shahil-kv/Memvo/blob/main/docs/FAQ.md")
    static let privacyPolicy = URL.literal("https://memvo.mshahilkv.workers.dev/privacy")
    static let license = URL.literal("https://www.gnu.org/licenses/gpl-3.0.html")

    /// Who "Message the developer" in Report a problem and Suggest a feature reaches, on Telegram.
    static let developerName = "Shahil"
    static let developerTelegram = "shahil9846"
}

/// Third-party code shipped inside the app, with the license each one is under.
enum Acknowledgement: CaseIterable, Identifiable {
    case tdlib, tdlibKit, tdlibFramework, openssl, argon2

    var id: Self { self }

    var name: String {
        switch self {
        case .tdlib: return "TDLib"
        case .tdlibKit: return "TDLibKit"
        case .tdlibFramework: return "TDLibFramework"
        case .openssl: return "OpenSSL"
        case .argon2: return "Argon2"
        }
    }

    var detail: String {
        switch self {
        case .tdlib: return "Telegram Database Library, © Aliaksei Levin and Arseny Smirnov. Boost Software License 1.0."
        case .tdlibKit: return "Swift bindings for TDLib, © 2021 Sergey Akentev. MIT License."
        case .tdlibFramework: return "TDLib packaged for Apple platforms, © 2024 Sergey Akentev. MIT License."
        case .openssl: return "Cryptography used by TDLib, © The OpenSSL Project Authors. Apache License 2.0."
        case .argon2: return "Passphrase key derivation, © 2015 Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson and Samuel Neves. CC0 1.0 or Apache License 2.0."
        }
    }

    var url: URL {
        switch self {
        case .tdlib: return .literal("https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt")
        case .tdlibKit: return .literal("https://github.com/Swiftgram/TDLibKit/blob/main/LICENSE")
        case .tdlibFramework: return .literal("https://github.com/Swiftgram/TDLibFramework/blob/main/LICENSE")
        case .openssl: return .literal("https://www.openssl.org/source/license.html")
        case .argon2: return .literal("https://github.com/P-H-C/phc-winner-argon2/blob/master/LICENSE")
        }
    }
}
