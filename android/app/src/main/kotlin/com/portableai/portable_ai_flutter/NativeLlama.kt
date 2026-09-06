package com.portableai.portable_ai_flutter

object NativeLlama {
    init {
        System.loadLibrary("portable_llama")
    }

    external fun nativeLoad(modelPath: String, nCtx: Int, nThreads: Int, nBatch: Int): Map<String, Any?>
    external fun nativeGenerate(prompt: String, maxTokens: Int, temperature: Float): String
    external fun nativeUnload()
}
