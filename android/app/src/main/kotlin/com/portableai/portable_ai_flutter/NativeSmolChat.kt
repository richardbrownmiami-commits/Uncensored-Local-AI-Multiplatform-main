package com.portableai.portable_ai_flutter

/** Thin Kotlin/JNI bridge to the native SmolChat-style llama.cpp engine. */
object NativeSmolChat {
    init { System.loadLibrary("smolchat_native") }

    data class LoadConfig(
        val contextSize: Long = 512L,
        val threads: Int = 2,
        val batch: Int = 128,
        val minP: Float = 0.05f,
        val temperature: Float = 0.7f,
        val useMmap: Boolean = true,
        val useMlock: Boolean = false,
        val storeChats: Boolean = false,
        val chatTemplate: String? = null,
    )

    private var handle = 0L

    fun load(path: String, config: LoadConfig = LoadConfig()) {
        close()
        handle = nativeLoad(path, config.minP, config.temperature, config.storeChats,
            config.contextSize, config.threads, config.batch, config.useMmap,
            config.useMlock, config.chatTemplate)
        check(handle != 0L) { "Native SmolChat engine returned an invalid model handle" }
    }

    fun addMessage(role: String, text: String) { verify(); nativeAddMessage(handle, text, role) }
    fun clearMessages() { verify(); nativeClearMessages(handle) }
    fun start(query: String): Boolean { verify(); return nativeStart(handle, query) }
    fun step(): String { verify(); return nativeStep(handle) }
    fun stop() { if (handle != 0L) nativeStop(handle) }
    fun setTemperature(value: Float) { verify(); nativeSetTemperature(handle, value) }
    fun speed(): Float = if (handle == 0L) 0f else nativeSpeed(handle)
    fun contextUsed(): Int = if (handle == 0L) 0 else nativeContextUsed(handle)
    fun close() { if (handle != 0L) { nativeClose(handle); handle = 0L } }
    private fun verify() { check(handle != 0L) { "Native SmolChat model is not loaded" } }

    private external fun nativeLoad(modelPath: String, minP: Float, temperature: Float,
        storeChats: Boolean, contextSize: Long, nThreads: Int, nBatch: Int,
        useMmap: Boolean, useMlock: Boolean, chatTemplate: String?): Long
    private external fun nativeAddMessage(handle: Long, message: String, role: String)
    private external fun nativeClearMessages(handle: Long)
    private external fun nativeStart(handle: Long, query: String): Boolean
    private external fun nativeStep(handle: Long): String
    private external fun nativeStop(handle: Long)
    private external fun nativeSetTemperature(handle: Long, temperature: Float)
    private external fun nativeSpeed(handle: Long): Float
    private external fun nativeContextUsed(handle: Long): Int
    private external fun nativeClose(handle: Long)
}
