#include "LLMInference.h"
#include <jni.h>
#include <stdexcept>

static std::string toString(JNIEnv* env, jstring value) {
    if (!value) return {};
    const char* raw = env->GetStringUTFChars(value, nullptr);
    std::string out = raw ? raw : "";
    if (raw) env->ReleaseStringUTFChars(value, raw);
    return out;
}

static LLMInference* ptr(jlong handle) { return reinterpret_cast<LLMInference*>(handle); }

static void throwState(JNIEnv* env, const std::exception& error) {
    jclass cls = env->FindClass("java/lang/IllegalStateException");
    env->ThrowNew(cls, error.what());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeLoad(
    JNIEnv* env, jobject, jstring modelPath, jfloat minP, jfloat temperature,
    jboolean storeChats, jlong contextSize, jint nThreads, jint nBatch,
    jboolean useMmap, jboolean useMlock, jstring chatTemplate) {
    try {
        const std::string path = toString(env, modelPath);
        const std::string tmpl = toString(env, chatTemplate);
        auto* inference = new LLMInference();
        inference->loadModel(path.c_str(), minP, temperature, storeChats,
                             (long)contextSize, tmpl.empty() ? nullptr : tmpl.c_str(),
                             nThreads, nBatch, useMmap, useMlock);
        return reinterpret_cast<jlong>(inference);
    } catch (const std::exception& error) { throwState(env, error); return 0; }
}

extern "C" JNIEXPORT void JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeAddMessage(
    JNIEnv* env, jobject, jlong handle, jstring message, jstring role) {
    try {
        const std::string text = toString(env, message);
        const std::string roleText = toString(env, role);
        ptr(handle)->addChatMessage(text.c_str(), roleText.c_str());
    } catch (const std::exception& error) { throwState(env, error); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeClearMessages(
    JNIEnv* env, jobject, jlong handle) {
    try { ptr(handle)->clearMessages(); }
    catch (const std::exception& error) { throwState(env, error); }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeStart(
    JNIEnv* env, jobject, jlong handle, jstring query) {
    try {
        const std::string text = toString(env, query);
        return ptr(handle)->startCompletion(text.c_str()) ? JNI_TRUE : JNI_FALSE;
    } catch (const std::exception& error) { throwState(env, error); return JNI_FALSE; }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeStep(
    JNIEnv* env, jobject, jlong handle) {
    try {
        const std::string piece = ptr(handle)->completionLoop();
        return env->NewStringUTF(piece.c_str());
    } catch (const std::exception& error) { throwState(env, error); return nullptr; }
}

extern "C" JNIEXPORT void JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeStop(
    JNIEnv* env, jobject, jlong handle) {
    try { ptr(handle)->stopCompletion(); }
    catch (const std::exception& error) { throwState(env, error); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeSetTemperature(
    JNIEnv* env, jobject, jlong handle, jfloat temperature) {
    try { ptr(handle)->setTemperature(temperature); }
    catch (const std::exception& error) { throwState(env, error); }
}

extern "C" JNIEXPORT jfloat JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeSpeed(JNIEnv*, jobject, jlong handle) {
    return ptr(handle)->getResponseGenerationSpeed();
}

extern "C" JNIEXPORT jint JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeContextUsed(JNIEnv*, jobject, jlong handle) {
    return ptr(handle)->getContextSizeUsed();
}

extern "C" JNIEXPORT void JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeSmolChat_nativeClose(JNIEnv*, jobject, jlong handle) {
    delete ptr(handle);
}
