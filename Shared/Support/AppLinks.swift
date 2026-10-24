import Foundation

/// Web pages the app links to (About, Settings, error screens). One place to change if the repository moves.
enum AppLinks {
    static let repository = URL.literal("https://github.com/shahil-kv/Memvo")
    static let faq = URL.literal("https://github.com/shahil-kv/Memvo/blob/main/docs/FAQ.md")
    static let privacyPolicy = URL.literal("https://github.com/shahil-kv/Memvo/blob/main/PRIVACY.md")
    static let reportProblem = URL.literal("https://github.com/shahil-kv/Memvo/issues/new/choose")
    static let license = URL.literal("https://www.gnu.org/licenses/gpl-3.0.html")
}

/// Third-party code shipped inside the app, with the license each one is under.
enum Acknowledgement: CaseIterable, Identifiable {
    case tdlib, tdlibKit, tdlibFramework, openssl

    var id: Self { self }

    var name: String {
        switch self {
        case .tdlib: return "TDLib"
        case .tdlibKit: return "TDLibKit"
        case .tdlibFramework: return "TDLibFramework"
        case .openssl: return "OpenSSL"
        }
    }

    var detail: String {
        switch self {
        case .tdlib: return "Telegram Database Library, © Aliaksei Levin and Arseny Smirnov. Boost Software License 1.0."
        case .tdlibKit: return "Swift bindings for TDLib, © 2021 Sergey Akentev. MIT License."
        case .tdlibFramework: return "TDLib packaged for Apple platforms, © 2024 Sergey Akentev. MIT License."
        case .openssl: return "Cryptography used by TDLib, © The OpenSSL Project Authors. Apache License 2.0."
        }
    }

    var url: URL {
        switch self {
        case .tdlib: return .literal("https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt")
        case .tdlibKit: return .literal("https://github.com/Swiftgram/TDLibKit/blob/main/LICENSE")
        case .tdlibFramework: return .literal("https://github.com/Swiftgram/TDLibFramework/blob/main/LICENSE")
        case .openssl: return .literal("https://www.openssl.org/source/license.html")
        }
    }
}
