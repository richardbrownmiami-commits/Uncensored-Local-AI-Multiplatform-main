package com.portableai.portable_ai_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "portable_ai/native_smolchat"
    private val nativeExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            nativeExecutor.execute {
                try {
                    when (call.method) {
                        "load" -> {
                            val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                            val path = args["path"] as? String ?: error("Model path is required")
                            NativeSmolChat.load(path, NativeSmolChat.LoadConfig(
                                contextSize = (args["contextSize"] as? Number)?.toLong() ?: 512L,
                                threads = (args["threads"] as? Number)?.toInt() ?: 2,
                                batch = (args["batch"] as? Number)?.toInt() ?: 128,
                                minP = (args["minP"] as? Number)?.toFloat() ?: 0.05f,
                                temperature = (args["temperature"] as? Number)?.toFloat() ?: 0.7f,
                                useMmap = args["useMmap"] as? Boolean ?: true,
                                useMlock = args["useMlock"] as? Boolean ?: false,
                                storeChats = args["storeChats"] as? Boolean ?: false,
                                chatTemplate = args["chatTemplate"] as? String,
                            ))
                            result.success(mapOf("ok" to true, "message" to "Native SmolChat llama.cpp model loaded"))
                        }
                        "addMessage" -> {
                            NativeSmolChat.addMessage(call.argument<String>("role") ?: "user", call.argument<String>("text") ?: "")
                            result.success(true)
                        }
                        "start" -> result.success(NativeSmolChat.start(call.argument<String>("query") ?: ""))
                        "step" -> result.success(NativeSmolChat.step())
                        "stop" -> { NativeSmolChat.stop(); result.success(true) }
                        "temperature" -> { NativeSmolChat.setTemperature(call.argument<Number>("value")?.toFloat() ?: 0.7f); result.success(true) }
                        "speed" -> result.success(NativeSmolChat.speed())
                        "contextUsed" -> result.success(NativeSmolChat.contextUsed())
                        "close" -> { NativeSmolChat.close(); result.success(true) }
                        else -> result.notImplemented()
                    }
                } catch (t: Throwable) {
                    result.error("NATIVE_SMOLCHAT", t.message ?: t.javaClass.simpleName, t.stackTraceToString())
                }
            }
        }
    }

    override fun onDestroy() {
        nativeExecutor.execute { NativeSmolChat.close() }
        nativeExecutor.shutdown()
        super.onDestroy()
    }
}
