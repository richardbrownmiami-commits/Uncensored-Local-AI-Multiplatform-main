package com.portableai.portable_ai_flutter

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Runs on the target Android device/ABI. CI pushes a real GGUF to the app's
 * external-files directory before Test Lab starts the instrumentation test.
 * This catches JNI/native crashes, model-load failures, context failures and
 * generation failures without requiring a developer to install the APK.
 */
class NativeSmolChatInstrumentationTest {
    private val tag = "NativeSmolChatCI"

    @After
    fun tearDown() {
        runCatching { NativeSmolChat.close() }
    }

    @Test
    fun loadAndGenerateSmolLm2Q8() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = File(context.getExternalFilesDir(null), "ci-model.gguf")

        Log.i(tag, "TEST_MODEL=${model.absolutePath}")
        Log.i(tag, "MODEL_EXISTS=${model.exists()} MODEL_BYTES=${model.length()}")
        assertTrue("CI GGUF was not pushed to the test device: ${model.absolutePath}", model.isFile)
        assertTrue("CI GGUF is unexpectedly small: ${model.length()} bytes", model.length() > 100_000_000L)

        Log.i(tag, "NATIVE_LOAD_START")
        NativeSmolChat.load(
            model.absolutePath,
            NativeSmolChat.LoadConfig(
                contextSize = 2048L,
                threads = 2,
                batch = 128,
                minP = 0.05f,
                temperature = 0.2f,
                useMmap = false,
                useMlock = false,
                storeChats = false,
            ),
        )
        Log.i(tag, "NATIVE_LOAD_OK context=${NativeSmolChat.contextUsed()}")

        NativeSmolChat.clearMessages()
        NativeSmolChat.addMessage("system", "Reply with one short word. Do not explain.")
        assertTrue("Native completion could not start", NativeSmolChat.start("Say READY."))

        val output = StringBuilder()
        var finished = false
        repeat(96) {
            val token = NativeSmolChat.step()
            if (token.isNotEmpty()) output.append(token)
            if (token.isEmpty()) {
                finished = true
                return@repeat
            }
        }

        val text = output.toString()
        Log.i(tag, "NATIVE_GENERATION_OK=$finished")
        Log.i(tag, "NATIVE_OUTPUT=$text")
        Log.i(tag, "NATIVE_CONTEXT_USED=${NativeSmolChat.contextUsed()}")
        Log.i(tag, "NATIVE_SPEED=${NativeSmolChat.speed()}")

        assertTrue("Native engine returned no generated token", text.isNotBlank())
        assertTrue("Native engine exceeded context", NativeSmolChat.contextUsed() <= 2048)
    }
}
