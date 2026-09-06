#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include <mutex>
#include <cmath>
#include "llama.h"

#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "PortableLLM", __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "PortableLLM", __VA_ARGS__)

namespace {
std::mutex g_mutex;
llama_model * g_model = nullptr;
llama_context * g_ctx = nullptr;
llama_sampler * g_sampler = nullptr;
int g_ctx_size = 512;
int g_threads = 2;

void free_engine_locked() {
    if (g_sampler) { llama_sampler_free(g_sampler); g_sampler = nullptr; }
    if (g_ctx) { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
}

std::string jstr(JNIEnv * env, jstring value) {
    if (!value) return {};
    const char * raw = env->GetStringUTFChars(value, nullptr);
    std::string out = raw ? raw : "";
    if (raw) env->ReleaseStringUTFChars(value, raw);
    return out;
}

jobject result(JNIEnv * env, bool ok, const std::string & message) {
    jclass cls = env->FindClass("java/util/HashMap");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "()V");
    jobject map = env->NewObject(cls, ctor);
    jmethodID put = env->GetMethodID(cls, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    jclass boolCls = env->FindClass("java/lang/Boolean");
    jmethodID boolValue = env->GetStaticMethodID(boolCls, "valueOf", "(Z)Ljava/lang/Boolean;");
    jstring okKey = env->NewStringUTF("ok");
    jobject okVal = env->CallStaticObjectMethod(boolCls, boolValue, ok ? JNI_TRUE : JNI_FALSE);
    env->CallObjectMethod(map, put, okKey, okVal);
    jstring msgKey = env->NewStringUTF("message");
    jstring msgVal = env->NewStringUTF(message.c_str());
    env->CallObjectMethod(map, put, msgKey, msgVal);
    env->DeleteLocalRef(okKey); env->DeleteLocalRef(okVal); env->DeleteLocalRef(msgKey); env->DeleteLocalRef(msgVal);
    return map;
}
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeLlama_nativeLoad(JNIEnv * env, jobject, jstring modelPath, jint nCtx, jint nThreads, jint nBatch) {
    std::lock_guard<std::mutex> lock(g_mutex);
    const std::string path = jstr(env, modelPath);
    if (path.empty()) return result(env, false, "Model path is empty");

    free_engine_locked();
    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    mp.use_mmap = true;
    mp.use_mlock = false;

    LOGI("Loading GGUF with native llama.cpp: %s", path.c_str());
    g_model = llama_model_load_from_file(path.c_str(), mp);
    if (!g_model) {
        return result(env, false, "llama.cpp could not load the GGUF model");
    }

    llama_context_params cp = llama_context_default_params();
    g_ctx_size = nCtx > 0 ? nCtx : 512;
    g_threads = nThreads > 0 ? nThreads : 2;
    cp.n_ctx = g_ctx_size;
    cp.n_batch = nBatch > 0 ? nBatch : g_ctx_size;
    cp.n_ubatch = cp.n_batch;
    cp.n_threads = g_threads;
    cp.n_threads_batch = g_threads;

    g_ctx = llama_init_from_model(g_model, cp);
    if (!g_ctx) {
        free_engine_locked();
        return result(env, false, "llama.cpp loaded the model but could not create its context");
    }

    g_sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(g_sampler, llama_sampler_init_min_p(0.05f, 1));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    return result(env, true, "Native SmolChat-style llama.cpp engine ready");
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeLlama_nativeGenerate(JNIEnv * env, jobject, jstring prompt, jint maxTokens, jfloat temperature) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_model || !g_ctx || !g_sampler) return env->NewStringUTF("ERROR: native llama.cpp model is not loaded");
    const std::string input = jstr(env, prompt);
    if (input.empty()) return env->NewStringUTF("");

    llama_sampler_reset(g_sampler);
    llama_sampler_chain_add(g_sampler, llama_sampler_init_min_p(0.05f, 1));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(std::max(0.0f, (float)temperature)));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    const llama_vocab * vocab = llama_model_get_vocab(g_model);
    const bool addSpecial = true;
    const int needed = -llama_tokenize(vocab, input.c_str(), (int)input.size(), nullptr, 0, true, addSpecial);
    if (needed <= 0) return env->NewStringUTF("ERROR: tokenization failed");
    std::vector<llama_token> tokens((size_t)needed);
    if (llama_tokenize(vocab, input.c_str(), (int)input.size(), tokens.data(), (int)tokens.size(), true, addSpecial) < 0) {
        return env->NewStringUTF("ERROR: tokenization failed");
    }

    llama_memory_clear(llama_get_memory(g_ctx), true);
    llama_batch batch = llama_batch_get_one(tokens.data(), tokens.size());
    std::string output;
    const int limit = maxTokens > 0 ? maxTokens : 256;

    for (int generated = 0; generated < limit; ++generated) {
        const int used = (int)llama_memory_seq_pos_max(llama_get_memory(g_ctx), 0) + 1;
        if (used + batch.n_tokens > g_ctx_size) break;
        const int rc = llama_decode(g_ctx, batch);
        if (rc != 0) {
            return env->NewStringUTF("ERROR: llama.cpp decode failed");
        }
        const llama_token token = llama_sampler_sample(g_sampler, g_ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) break;

        char buf[512];
        const int n = llama_token_to_piece(vocab, token, buf, sizeof(buf), 0, true);
        if (n > 0) output.append(buf, n);
        batch = llama_batch_get_one(const_cast<llama_token *>(&token), 1);
    }
    return env->NewStringUTF(output.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_portableai_portable_1ai_1flutter_NativeLlama_nativeUnload(JNIEnv *, jobject) {
    std::lock_guard<std::mutex> lock(g_mutex);
    free_engine_locked();
}
