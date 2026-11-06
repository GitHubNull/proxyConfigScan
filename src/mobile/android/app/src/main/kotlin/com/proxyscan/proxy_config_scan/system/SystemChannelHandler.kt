package com.proxyscan.proxy_config_scan.system

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.security.KeyChain
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.IOException
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Locale
import java.util.concurrent.Executors

/**
 * MethodChannel `proxy_scan/system`（与 iOS SystemChannelHandler 同 API 面）。
 * CA 安装受 Android 11+ 平台限制：仅能落下载目录 + 跳系统安全设置，由用户手动确认。
 */
class SystemChannelHandler(
    private val activity: Activity,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val METHOD_CHANNEL = "proxy_scan/system"
        private const val PREFS_NAME = "system_channel"
        private const val KEY_CA_SHA256 = "last_installed_ca_sha256"
        private const val MIN_CERT_BYTES = 64
        private const val MAX_CERT_BYTES = 64 * 1024
        private const val CA_FILE_NAME = "BurpSuite-CA.cer"
    }

    private val methodChannel =
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private val prefs by lazy {
        activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun attach() {
        methodChannel.setMethodCallHandler(this)
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "caStatus" -> handleCaStatus(result)
            "installCa" -> handleInstallCa(call, result)
            "openAppSettings" -> {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${activity.packageName}"),
                    ),
                )
                result.success(mapOf("ok" to true))
            }
            "openSecuritySettings" -> {
                val intent = Intent(Settings.ACTION_SECURITY_SETTINGS)
                if (intent.resolveActivity(activity.packageManager) != null) {
                    activity.startActivity(intent)
                    result.success(mapOf("ok" to true))
                } else {
                    result.success(mapOf("ok" to false))
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun handleCaStatus(result: MethodChannel.Result) {
        executor.execute {
            try {
                val expected = prefs.getString(KEY_CA_SHA256, null)
                var subject: String? = null
                var fingerprint: String? = null
                var installed = false
                var subjectFallback: X509Certificate? = null
                val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
                val aliases = store.aliases()
                while (aliases.hasMoreElements()) {
                    val alias = aliases.nextElement()
                    val cert = try {
                        store.getCertificate(alias) as? X509Certificate
                    } catch (_: Exception) {
                        null
                    } ?: continue
                    val sha256 = sha256Hex(cert.encoded)
                    if (expected != null && sha256.equals(expected, ignoreCase = true)) {
                        installed = true
                        subject = cert.subjectDN.name
                        fingerprint = sha256
                        break
                    }
                    if (subjectFallback == null &&
                        cert.subjectDN.name.contains("PortSwigger", ignoreCase = true)
                    ) {
                        subjectFallback = cert
                    }
                }
                if (!installed && subjectFallback != null) {
                    installed = true
                    subject = subjectFallback.subjectDN.name
                    fingerprint = sha256Hex(subjectFallback.encoded)
                }
                postSuccess(
                    result,
                    mapOf(
                        "supported" to true,
                        "installed" to installed,
                        "subject" to subject,
                        "fingerprintSha256" to fingerprint,
                    ),
                )
            } catch (e: Exception) {
                postError(result, "CA_INTERNAL", e.message ?: "证书状态查询失败")
            }
        }
    }

    private fun handleInstallCa(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<ByteArray>("bytes")
        val name = call.argument<String>("name")?.takeIf { it.isNotBlank() } ?: "PortSwigger CA"
        if (raw == null || raw.size < MIN_CERT_BYTES || raw.size > MAX_CERT_BYTES) {
            result.error("CA_INVALID_CERT", "证书内容为空或体积异常", null)
            return
        }
        val cert = try {
            CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(raw)) as X509Certificate
        } catch (e: Exception) {
            result.error("CA_INVALID_CERT", "证书解析失败", null)
            return
        }
        val certificateBytes = cert.encoded
        prefs.edit().putString(KEY_CA_SHA256, sha256Hex(certificateBytes)).apply()

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val intent = KeyChain.createInstallIntent().apply {
                putExtra(KeyChain.EXTRA_CERTIFICATE, certificateBytes)
                putExtra(KeyChain.EXTRA_NAME, name)
            }
            if (intent.resolveActivity(activity.packageManager) == null) {
                result.error("CA_UNSUPPORTED", "系统不支持证书安装器", null)
                return
            }
            activity.startActivity(intent)
            result.success(mapOf("state" to "launched"))
            return
        }

        executor.execute {
            try {
                saveToDownloads(CA_FILE_NAME, certificateBytes)
                activity.runOnUiThread {
                    runCatching {
                        activity.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                    }
                    result.success(
                        mapOf("state" to "saved", "fileName" to CA_FILE_NAME),
                    )
                }
            } catch (e: Exception) {
                postError(result, "CA_STORAGE_FAILED", e.message ?: "证书保存失败")
            }
        }
    }

    private fun saveToDownloads(displayName: String, bytes: ByteArray) {
        val resolver = activity.contentResolver
        val collection =
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val existingId = resolver.query(
            collection,
            arrayOf(MediaStore.Downloads._ID),
            "${MediaStore.Downloads.DISPLAY_NAME} = ?",
            arrayOf(displayName),
            null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getLong(0) else null }

        val uri: Uri
        if (existingId != null) {
            uri = ContentUris.withAppendedId(collection, existingId)
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 1) },
                null,
                null,
            )
        } else {
            uri = resolver.insert(
                collection,
                ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                    put(MediaStore.Downloads.MIME_TYPE, "application/x-x509-ca-cert")
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                },
            ) ?: throw IOException("无法创建下载文件")
        }
        resolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
            ?: throw IOException("无法写入下载文件")
        resolver.update(
            uri,
            ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
            null,
            null,
        )
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { String.format(Locale.US, "%02X", it) }

    private fun postSuccess(result: MethodChannel.Result, payload: Any?) {
        activity.runOnUiThread { result.success(payload) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        activity.runOnUiThread { result.error(code, message, null) }
    }
}
