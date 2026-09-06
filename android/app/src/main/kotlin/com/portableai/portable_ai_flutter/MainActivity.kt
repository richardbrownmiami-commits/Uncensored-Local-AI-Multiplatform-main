package com.portableai.portable_ai_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "portable_ai/native_llama"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "load" -> {
                        val path = call.argument<String>("path") ?: throw IllegalArgumentException("Missing model path")
                        val context = call.argument<Int>("context") ?: 512
                        val threads = call.argument<Int>("threads") ?: 2
                        val batch = call.argument<Int>("batch") ?: 128
                        result.success(NativeLlama.nativeLoad(path, context, threads, batch))
                    }
                    "generate" -> {
                        val prompt = call.argument<String>("prompt") ?: ""
                        val maxTokens = call.argument<Int>("maxTokens") ?: 256
                        val temperature = (call.argument<Double>("temperature") ?: 0.7).toFloat()
                        result.success(NativeLlama.nativeGenerate(prompt, maxTokens, temperature))
                    }
                    "unload" -> {
                        NativeLlama.nativeUnload()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("NATIVE_LLAMA", t.message ?: t.javaClass.simpleName, null)
            }
        }
    }

    override fun onDestroy() {
        try { NativeLlama.nativeUnload() } catch (_: Throwable) {}
        super.onDestroy()
    }
}
