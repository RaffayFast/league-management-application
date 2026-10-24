package com.nascon.leaguehub

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Forwards nascon:// deep links (Day 2 spec 6.3) to Dart.
 * - getInitialLink: the URI that launched the activity (cold start), returned once.
 * - onLink: pushed to Dart when a link arrives while the app is running (singleTop -> onNewIntent).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var initialLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialLink = intent?.data?.toString()
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        result.success(initialLink)
                        initialLink = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.data?.toString()?.let { channel?.invokeMethod("onLink", it) }
    }

    companion object {
        private const val CHANNEL = "leaguehub/deeplinks"
    }
}
