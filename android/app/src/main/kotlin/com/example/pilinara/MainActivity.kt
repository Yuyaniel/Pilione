package com.example.pilinara

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private lateinit var methodChannel: MethodChannel
    private lateinit var shareChannel: MethodChannel

    // 冷启动时 Dart 侧的 handler 尚未注册，先把分享文本缓存下来，等 Dart 主动来取
    private var pendingShareText: String? = null
    private var shareSeq = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "Pilione")
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                else -> result.notImplemented()
            }
        }

        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "Pilione/share")
        shareChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeSharedText" -> {
                    val text = pendingShareText
                    result.success(
                        if (text == null) null
                        else mapOf("text" to text, "seq" to shareSeq)
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        if (intent.type?.startsWith("text/") != true) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
        if (text.isBlank()) return
        shareSeq += 1
        pendingShareText = text
        // 热启动时 Dart handler 已注册，直接推过去；冷启动这次推送会被丢弃，
        // 由 Dart 侧 init 时的 consumeSharedText 兜底（seq 相同会去重）
        if (!::shareChannel.isInitialized) return
        shareChannel.invokeMethod(
            "onSharedText",
            mapOf("text" to text, "seq" to shareSeq),
        )
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
        methodChannel.invokeMethod("onPipChanged", isInPictureInPictureMode)
    }
}
