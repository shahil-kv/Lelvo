package app.lelvo.core.crypto

/** Why encrypted data couldn't be read or a key couldn't be derived. The messages carry no secrets. */
sealed class CryptoException(message: String) : Exception(message) {
    class BadFormat : CryptoException("This file is not a Lelvo encrypted file.")
    class UnsupportedVersion(val version: Int) : CryptoException("Unsupported encrypted file version $version. Update the app.")
    class WrongKeyOrCorrupt : CryptoException("Wrong passphrase, or the file is damaged.")

    /** Also thrown when a header asks for a cost beyond what Lelvo computes: the library is still an encrypted one. */
    class DerivationFailed : CryptoException("Could not derive the encryption key.")
    class Truncated : CryptoException("The encrypted file is incomplete.")
}
