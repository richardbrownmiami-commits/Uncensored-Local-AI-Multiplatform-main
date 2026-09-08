#include "LLMInference.h"
#include <android/log.h>
#include <algorithm>
#include <cstring>
#include <stdexcept>

#define TAG "PortableAI-SmolChat"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {
static int countTokens(const llama_vocab* vocab, const std::string& text) {
    const int n = llama_tokenize(vocab, text.c_str(), (int)text.size(), nullptr, 0, true, true);
    return n < 0 ? -n : n;
}

// Use llama.cpp's single-sequence helper instead of manually assigning KV
// positions. The helper lets llama_decode track the next position from the
// context memory, which is important on the 32-bit ARMv7 build.
static bool decodePrompt(llama_context* ctx, const std::vector<llama_token>& tokens, int requestedBatch) {
    if (tokens.empty()) return false;
    int batchSize = std::max(1, std::min(requestedBatch, 16));
    for (int start = 0; start < (int)tokens.size();) {
        int count = std::min(batchSize, (int)tokens.size() - start);
        while (true) {
            llama_batch batch = llama_batch_get_one(const_cast<llama_token *>(tokens.data() + start), count);
            const int rc = llama_decode(ctx, batch);
            if (rc == 0) {
                start += count;
                break;
            }
            LOGE("prompt decode failed rc=%d start=%d count=%d", rc, start, count);
            if (count == 1) return false;
            count = std::max(1, count / 2);
        }
    }
    return true;
}
}

void LLMInference::loadModel(const char* modelPath, float minP, float temperature, bool storeChats,
                             long contextSize, const char* chatTemplate, int nThreads, int nBatch,
                             bool useMmap, bool useMlock) {
    (void) useMmap;
    (void) useMlock;
    LOGI("loadModel path=%s ctx=%ld batch=%d threads=%d", modelPath, contextSize, nBatch, nThreads);
    llama_backend_init();

    llama_model_params modelParams = llama_model_default_params();
    modelParams.n_gpu_layers = 0;
    _model = llama_model_load_from_file(modelPath, modelParams);
    if (!_model) throw std::runtime_error("llama.cpp failed to load GGUF model");

    llama_context_params ctxParams = llama_context_default_params();
    ctxParams.n_ctx = contextSize > 0 ? contextSize : 2048;
    ctxParams.n_batch = nBatch > 0 ? std::min<int>(nBatch, (int)ctxParams.n_ctx) : 128;
    ctxParams.n_ubatch = 1;
    ctxParams.n_threads = nThreads > 0 ? nThreads : 2;
    ctxParams.n_threads_batch = ctxParams.n_threads;
    ctxParams.no_perf = true;
    _ctx = llama_init_from_model(_model, ctxParams);
    if (!_ctx) throw std::runtime_error("llama.cpp loaded the GGUF but could not create a context");

    auto samplerParams = llama_sampler_chain_default_params();
    samplerParams.no_perf = true;
    _sampler = llama_sampler_chain_init(samplerParams);
    llama_sampler_chain_add(_sampler, llama_sampler_init_min_p(minP, 1));
    llama_sampler_chain_add(_sampler, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(_sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    _response.clear();
    _cacheResponseTokens.clear();
    _promptTokens.clear();
    _ownedChatTemplate.clear();
    _chatTemplate = nullptr;
    if (chatTemplate && *chatTemplate) {
        _ownedChatTemplate = chatTemplate;
        _chatTemplate = _ownedChatTemplate.c_str();
    } else {
        const char* tmpl = llama_model_chat_template(_model, nullptr);
        if (tmpl) {
            _ownedChatTemplate = tmpl;
            _chatTemplate = _ownedChatTemplate.c_str();
        }
    }
    _storeChats = storeChats;
    _nCtxUsed = 0;
    _responseNumTokens = 0;
    _responseGenerationTime = 0;
}

void LLMInference::clearMessagesInternal() {
    for (llama_chat_message& message : _messages) {
        free(const_cast<char*>(message.role));
        free(const_cast<char*>(message.content));
    }
    _messages.clear();
}

void LLMInference::clearMessages() {
    clearMessagesInternal();
    _response.clear();
    _cacheResponseTokens.clear();
    _promptTokens.clear();
    _nCtxUsed = 0;
    if (_sampler) llama_sampler_reset(_sampler);
    if (_ctx) llama_memory_clear(llama_get_memory(_ctx), true);
}

void LLMInference::addChatMessage(const char* message, const char* role) {
    _messages.push_back({strdup(role), strdup(message)});
}

float LLMInference::getResponseGenerationSpeed() const {
    if (_responseGenerationTime <= 0) return 0.0f;
    return (float)_responseNumTokens / ((float)_responseGenerationTime / 1000000.0f);
}

int LLMInference::getContextSizeUsed() const { return _nCtxUsed; }

bool LLMInference::startCompletion(const char* query) {
    if (!_ctx || !_model || !_sampler) throw std::runtime_error("Native model is not initialized");

    _response.clear();
    _cacheResponseTokens.clear();
    _responseGenerationTime = 0;
    _responseNumTokens = 0;
    addChatMessage(query, "user");
    llama_memory_clear(llama_get_memory(_ctx), true);
    llama_sampler_reset(_sampler);

    const auto* vocab = llama_model_get_vocab(_model);
    const uint32_t contextSize = llama_n_ctx(_ctx);
    const int responseReserve = std::min<int>(256, std::max<int>(64, (int)contextSize / 8));

    auto templates = common_chat_templates_init(_model, _chatTemplate ? _chatTemplate : "");
    common_chat_templates_inputs inputs;
    inputs.use_jinja = true;
    inputs.add_generation_prompt = true;
    inputs.add_bos = false;
    inputs.add_eos = false;
    inputs.tools.clear();
    inputs.tool_choice = COMMON_CHAT_TOOL_CHOICE_NONE;
    inputs.enable_thinking = true;

    std::string prompt;
    int tokenCount = 0;

    while (true) {
        std::vector<common_chat_msg> messages;
        messages.reserve(_messages.size());
        for (const auto& message : _messages) {
            common_chat_msg msg;
            msg.role = message.role;
            msg.content = message.content;
            messages.push_back(std::move(msg));
        }
        inputs.messages = messages;
        try {
            const common_chat_params rendered = common_chat_templates_apply(templates.get(), inputs);
            prompt = rendered.prompt;
            LOGI("chat template=%s generation_prompt=%s prompt_chars=%d",
                 common_chat_templates_source(templates.get()).c_str(),
                 inputs.add_generation_prompt ? "true" : "false",
                 (int)prompt.size());
        } catch (const std::exception& error) {
            LOGE("Jinja chat template failed: %s", error.what());
            inputs.use_jinja = false;
            prompt = common_chat_templates_apply(templates.get(), inputs).prompt;
        }

        tokenCount = countTokens(vocab, prompt);
        if (tokenCount <= 0) throw std::runtime_error("llama.cpp could not tokenize the rendered chat prompt");
        if (tokenCount + responseReserve < (int)contextSize || _messages.size() <= 2) break;

        const size_t removeIndex = 1;
        if (_messages.size() <= removeIndex + 1) break;
        free(const_cast<char*>(_messages[removeIndex].role));
        free(const_cast<char*>(_messages[removeIndex].content));
        _messages.erase(_messages.begin() + (long)removeIndex);
        LOGI("Context trim: removed oldest turn; promptTokens=%d ctx=%u reserve=%d", tokenCount, contextSize, responseReserve);
    }

    if (tokenCount + responseReserve >= (int)contextSize) {
        throw std::runtime_error("system prompt and user message exceed native context; reduce prompt/skills/tools or increase context");
    }

    _promptTokens.resize((size_t)tokenCount);
    const int written = llama_tokenize(vocab, prompt.c_str(), (int)prompt.size(),
                                       _promptTokens.data(), tokenCount, true, true);
    if (written < 0) throw std::runtime_error("llama.cpp prompt tokenization failed");
    if (written != tokenCount) _promptTokens.resize((size_t)written);

    const int batchSize = std::max(1, std::min<int>(16, (int)llama_n_batch(_ctx)));
    if (!decodePrompt(_ctx, _promptTokens, batchSize)) {
        throw std::runtime_error("llama_decode failed while processing prompt; ARMv7 decoder reached batch size 1");
    }

    _nCtxUsed = (int)_promptTokens.size();
    LOGI("Completion promptTokens=%d ctx=%u responseReserve=%d ubatch=1", _nCtxUsed, contextSize, responseReserve);
    return true;
}

bool LLMInference::_isValidUtf8(const char* response) {
    if (!response) return true;
    const unsigned char* bytes = (const unsigned char*)response;
    int num;
    while (*bytes != 0x00) {
        if ((*bytes & 0x80) == 0x00) num = 1;
        else if ((*bytes & 0xE0) == 0xC0) num = 2;
        else if ((*bytes & 0xF0) == 0xE0) num = 3;
        else if ((*bytes & 0xF8) == 0xF0) num = 4;
        else return false;
        bytes++;
        for (int i = 1; i < num; ++i) {
            if ((*bytes & 0xC0) != 0x80) return false;
            bytes++;
        }
    }
    return true;
}

std::string LLMInference::completionLoop() {
    if (!_ctx || !_model || !_sampler) throw std::runtime_error("Native model is not initialized");
    const uint32_t contextSize = llama_n_ctx(_ctx);

    if (_nCtxUsed + 1 >= (int)contextSize) {
        LOGI("Generation context exhausted: used=%d ctx=%u", _nCtxUsed, contextSize);
        return "[EOG]";
    }

    const auto start = ggml_time_us();
    const llama_token token = llama_sampler_sample(_sampler, _ctx, -1);

    if (llama_vocab_is_eog(llama_model_get_vocab(_model), token)) {
        if (_storeChats) addChatMessage(_response.c_str(), "assistant");
        return "[EOG]";
    }

    llama_sampler_accept(_sampler, token);

    // Match the normal llama.cpp/SmolChat generation path: positions are
    // automatically advanced by llama_decode instead of being manually set.
    llama_batch batch = llama_batch_get_one(const_cast<llama_token*>(&token), 1);
    const int rc = llama_decode(_ctx, batch);
    if (rc != 0) throw std::runtime_error("llama_decode failed during token generation");

    _nCtxUsed++;
    const auto end = ggml_time_us();
    _responseGenerationTime += end - start;
    _responseNumTokens++;

    const std::string piece = common_token_to_piece(_ctx, token, true);
    if (!piece.empty()) _cacheResponseTokens += piece;

    if (_isValidUtf8(_cacheResponseTokens.c_str())) {
        _response += _cacheResponseTokens;
        std::string output = _cacheResponseTokens;
        _cacheResponseTokens.clear();
        return output;
    }
    return "";
}

void LLMInference::stopCompletion() {
    if (_storeChats && !_response.empty()) addChatMessage(_response.c_str(), "assistant");
    _response.clear();
    _cacheResponseTokens.clear();
}

void LLMInference::setTemperature(float temperature) {
    if (!_sampler) return;
    llama_sampler_free(_sampler);
    auto params = llama_sampler_chain_default_params();
    params.no_perf = true;
    _sampler = llama_sampler_chain_init(params);
    llama_sampler_chain_add(_sampler, llama_sampler_init_min_p(0.05f, 1));
    llama_sampler_chain_add(_sampler, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(_sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
}

LLMInference::~LLMInference() {
    clearMessagesInternal();
    if (_sampler) llama_sampler_free(_sampler);
    if (_ctx) llama_free(_ctx);
    if (_model) llama_model_free(_model);
}
