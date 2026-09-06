#include "LLMInference.h"
#include <android/log.h>
#include <cstring>
#include <stdexcept>

#define TAG "PortableAI-SmolChat"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

void LLMInference::loadModel(const char* modelPath, float minP, float temperature, bool storeChats,
                             long contextSize, const char* chatTemplate, int nThreads, int nBatch,
                             bool useMmap, bool useMlock) {
    // The pinned llama.cpp C API owns mmap/mlock policy in its default model params.
    // Keep the public SmolChat-compatible arguments for the Flutter/JNI layer, but do
    // not access removed fields from newer llama_model_params structs.
    LOGI("loadModel path=%s ctx=%ld batch=%d threads=%d mmap=%d mlock=%d",
         modelPath, contextSize, nBatch, nThreads, useMmap, useMlock);
    llama_backend_init();
    llama_model_params modelParams = llama_model_default_params();
    modelParams.n_gpu_layers = 0;
    _model = llama_model_load_from_file(modelPath, modelParams);
    if (!_model) throw std::runtime_error("llama.cpp failed to load GGUF model");

    llama_context_params ctxParams = llama_context_default_params();
    ctxParams.n_ctx = contextSize > 0 ? contextSize : 512;
    ctxParams.n_batch = nBatch > 0 ? nBatch : ctxParams.n_ctx;
    ctxParams.n_ubatch = ctxParams.n_batch;
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

    _formattedMessages = std::vector<char>(llama_n_ctx(_ctx));
    clearMessagesInternal();
    _response.clear();
    _cacheResponseTokens.clear();
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
    _response.clear();
    _cacheResponseTokens.clear();
    _responseGenerationTime = 0;
    _responseNumTokens = 0;
    addChatMessage(query, "user");

    std::vector<common_chat_msg> messages;
    messages.reserve(_messages.size());
    for (const auto& message : _messages) {
        common_chat_msg msg;
        msg.role = message.role;
        msg.content = message.content;
        messages.push_back(std::move(msg));
    }

    auto templates = common_chat_templates_init(_model, _chatTemplate ? _chatTemplate : "");
    common_chat_templates_inputs inputs;
    inputs.messages = messages;
    inputs.use_jinja = true;
    inputs.chat_template_kwargs["tools"] = "[]";

    std::string prompt;
    bool usedJinja = true;
    try {
        prompt = common_chat_templates_apply(templates.get(), inputs).prompt;
    } catch (const std::exception& error) {
        LOGE("Jinja chat template failed: %s; using legacy renderer", error.what());
        inputs.use_jinja = false;
        inputs.chat_template_kwargs.clear();
        prompt = common_chat_templates_apply(templates.get(), inputs).prompt;
        usedJinja = false;
    }

    const auto* vocab = llama_model_get_vocab(_model);
    const int tokenCount = -llama_tokenize(vocab, prompt.c_str(), (int)prompt.size(), nullptr, 0, true, true);
    if (tokenCount <= 0) throw std::runtime_error("llama.cpp could not tokenize the rendered chat prompt");
    _promptTokens.resize((size_t)tokenCount);
    const int written = llama_tokenize(vocab, prompt.c_str(), (int)prompt.size(), _promptTokens.data(), tokenCount, true, true);
    if (written < 0) throw std::runtime_error("llama.cpp prompt tokenization failed");

    delete _batch;
    _batch = new llama_batch();
    _batch->token = _promptTokens.data();
    _batch->n_tokens = _promptTokens.size();
    return usedJinja;
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
    const uint32_t contextSize = llama_n_ctx(_ctx);
    _nCtxUsed = (int)llama_memory_seq_pos_max(llama_get_memory(_ctx), 0) + 1;
    if (_nCtxUsed + (int)_batch->n_tokens > (int)contextSize) throw std::runtime_error("context size reached");

    const auto start = ggml_time_us();
    if (llama_decode(_ctx, *_batch) < 0) throw std::runtime_error("llama_decode failed");
    _currToken = llama_sampler_sample(_sampler, _ctx, -1);
    if (llama_vocab_is_eog(llama_model_get_vocab(_model), _currToken)) {
        if (_storeChats) addChatMessage(_response.c_str(), "assistant");
        return "[EOG]";
    }

    char pieceBuffer[4096];
    const int pieceLength = llama_token_to_piece(llama_model_get_vocab(_model), _currToken,
                                                  pieceBuffer, sizeof(pieceBuffer), 0, true);
    if (pieceLength > 0) _cacheResponseTokens.append(pieceBuffer, pieceLength);
    const auto end = ggml_time_us();
    _responseGenerationTime += end - start;
    _responseNumTokens++;
    _batch->token = &_currToken;
    _batch->n_tokens = 1;

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
    delete _batch;
    if (_sampler) llama_sampler_free(_sampler);
    if (_ctx) llama_free(_ctx);
    if (_model) llama_model_free(_model);
}
