package com.portableai.portable_ai_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "portable_ai/native_llama"
    private val nativeExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "load" -> {
                    val path = call.argument<String>("path") ?: ""
                    val context = call.argument<Int>("context") ?: 512
                    val threads = call.argument<Int>("threads") ?: 2
                    val batch = call.argument<Int>("batch") ?: 128
                    nativeExecutor.execute {
                        try { result.success(NativeLlama.nativeLoad(path, context, threads, batch)) }
                        catch (t: Throwable) { result.error("NATIVE_LLAMA", t.message ?: t.javaClass.simpleName, null) }
                    }
                }
                "generate" -> {
                    val prompt = call.argument<String>("prompt") ?: ""
                    val maxTokens = call.argument<Int>("maxTokens") ?: 256
                    val temperature = (call.argument<Double>("temperature") ?: 0.7).toFloat()
                    nativeExecutor.execute {
                        try { result.success(NativeLlama.nativeGenerate(prompt, maxTokens, temperature)) }
                        catch (t: Throwable) { result.error("NATIVE_LLAMA", t.message ?: t.javaClass.simpleName, null) }
                    }
                }
                "unload" -> {
                    nativeExecutor.execute {
                        try { NativeLlama.nativeUnload(); result.success(null) }
                        catch (t: Throwable) { result.error("NATIVE_LLAMA", t.message ?: t.javaClass.simpleName, null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        try { NativeLlama.nativeUnload() } catch (_: Throwable) {}
        nativeExecutor.shutdownNow()
        super.onDestroy()
    }
}
