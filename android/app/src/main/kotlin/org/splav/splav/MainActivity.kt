package org.splav.splav

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "splav/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppDataDirectory" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "splav/session")
            .setMethodCallHandler { call, result ->
                try {
                    val key = call.argument<String>("key")
                    require(key != null && key.matches(Regex("[a-f0-9]{64}")))
                    val prefs = getSharedPreferences("sessions", MODE_PRIVATE)
                    when (call.method) {
                        "read" -> {
                            val stored = prefs.getString(key, null)
                            if (stored == null) {
                                result.success(null)
                            } else {
                                val bytes = Base64.decode(stored, Base64.NO_WRAP)
                                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                                cipher.init(Cipher.DECRYPT_MODE, sessionKey(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                                result.success(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
                            }
                        }
                        "write" -> {
                            val value = requireNotNull(call.argument<String>("value"))
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.ENCRYPT_MODE, sessionKey())
                            val encrypted = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                            check(prefs.edit().putString(key, Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
                            result.success(null)
                        }
                        "delete" -> {
                            check(prefs.edit().remove(key).commit())
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("session_storage", "Не удалось открыть защищённый сеанс", null)
                }
            }
    }

    private fun sessionKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "splav-session-v1"
        if (store.containsAlias(alias)) return store.getKey(alias, null) as SecretKey
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
}
