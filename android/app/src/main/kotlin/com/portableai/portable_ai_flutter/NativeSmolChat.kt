package com.portableai.portable_ai_flutter

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Thin Kotlin/JNI bridge to the SmolChat-style native llama.cpp engine.
 * Flutter talks to this class through MainActivity's MethodChannel.
 */
object NativeSmolChat {
    init {
        System.loadLibrary("smolchat_native")
    }

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

    private var handle: Long = 0L

    suspend fun load(path: String, config: LoadConfig = LoadConfig()): Unit = withContext(Dispatchers.IO) {
        close()
        handle = nativeLoad(
            path,
            config.minP,
            config.temperature,
            config.storeChats,
            config.contextSize,
            config.threads,
            config.batch,
            config.useMmap,
            config.useMlock,
            config.chatTemplate,
        )
        if (handle == 0L) error("Native SmolChat engine returned an invalid model handle")
    }

    fun addMessage(role: String, text: String) {
        verify()
        nativeAddMessage(handle, text, role)
    }

    suspend fun start(query: String): Boolean = withContext(Dispatchers.IO) {
        verify()
        nativeStart(handle, query)
    }

    suspend fun step(): String = withContext(Dispatchers.IO) {
        verify()
        nativeStep(handle)
    }

    fun stop() {
        if (handle != 0L) nativeStop(handle)
    }

    fun setTemperature(value: Float) {
        verify()
        nativeSetTemperature(handle, value)
    }

    fun speed(): Float = if (handle == 0L) 0f else nativeSpeed(handle)

    fun contextUsed(): Int = if (handle == 0L) 0 else nativeContextUsed(handle)

    fun close() {
        if (handle != 0L) {
            nativeClose(handle)
            handle = 0L
        }
    }

    private fun verify() {
        check(handle != 0L) { "Native SmolChat model is not loaded" }
    }

    private external fun nativeLoad(
        modelPath: String,
        minP: Float,
        temperature: Float,
        storeChats: Boolean,
        contextSize: Long,
        nThreads: Int,
        nBatch: Int,
        useMmap: Boolean,
        useMlock: Boolean,
        chatTemplate: String?,
    ): Long

    private external fun nativeAddMessage(handle: Long, message: String, role: String)
    private external fun nativeStart(handle: Long, query: String): Boolean
    private external fun nativeStep(handle: Long): String
    private external fun nativeStop(handle: Long)
    private external fun nativeSetTemperature(handle: Long, temperature: Float)
    private external fun nativeSpeed(handle: Long): Float
    private external fun nativeContextUsed(handle: Long): Int
    private external fun nativeClose(handle: Long)
}
