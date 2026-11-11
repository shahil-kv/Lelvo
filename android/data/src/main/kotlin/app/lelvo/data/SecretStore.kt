package app.lelvo.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import app.lelvo.telegram.DatabaseKeyStore
import app.lelvo.telegram.StoredKey
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small secrets (Telegram's database key, later the library's master key) sealed with an AES key that never leaves
 * the Android Keystore. The Android counterpart of the iOS Keychain store. Files live in the app's no-backup folder,
 * so they never travel to another phone through Android backup (the iOS app excludes them from backup too).
 */
class SecretStore(context: Context) {
    private val dir = File(context.noBackupFilesDir, "secrets").apply { mkdirs() }

    sealed interface Read {
        data class Found(val value: ByteArray) : Read
        data object Missing : Read
        data object Failed : Read
    }

    fun read(name: String): Read {
        val file = File(dir, "$name.bin")
        if (!file.exists()) return Read.Missing
        return try {
            val blob = file.readBytes()
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, wrapKey(create = false) ?: return Read.Failed, GCMParameterSpec(128, blob, 0, IV))
            Read.Found(cipher.doFinal(blob, IV, blob.size - IV))
        } catch (e: Exception) {
            // Never treat this as missing: making a new secret here would lose what the old one protected.
            Log.w(TAG, "Couldn't read a secret (${e.javaClass.simpleName})")
            Read.Failed
        }
    }

    fun write(name: String, value: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey(create = true))
        val blob = cipher.iv + cipher.doFinal(value)
        val tmp = File(dir, "$name.tmp")
        tmp.writeBytes(blob)
        // Rename is atomic: a crash mid-write never leaves half a secret behind.
        check(tmp.renameTo(File(dir, "$name.bin"))) { "Couldn't save a secret" }
    }

    fun delete(name: String) { File(dir, "$name.bin").delete() }

    private fun wrapKey(create: Boolean): SecretKey? {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        if (!create) return null
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    /** Telegram's database key, with the read states TDLib start-up needs. */
    fun telegramDatabaseKeys(): DatabaseKeyStore = object : DatabaseKeyStore {
        override fun read(): StoredKey = when (val r = read(TD_DATABASE_KEY)) {
            is Read.Found -> StoredKey.Found(r.value)
            Read.Missing -> StoredKey.Missing
            Read.Failed -> StoredKey.Failed
        }
        override fun write(key: ByteArray) = write(TD_DATABASE_KEY, key)
    }

    private companion object {
        const val TAG = "Lelvo.Secrets"
        const val ALIAS = "lelvo.secrets.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV = 12
        const val TD_DATABASE_KEY = "td-database-key"
    }
}
