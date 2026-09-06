#pragma once

#include "chat.h"
#include "common.h"
#include "llama.h"
#include <string>
#include <vector>

// Adapted from SmolChat-Android's LLMInference architecture. See
// android/app/src/main/cpp/SMOLCHAT_NOTICE.txt.
class LLMInference {
    llama_context* _ctx = nullptr;
    llama_model*   _model = nullptr;
    llama_sampler* _sampler = nullptr;
    llama_token    _currToken = 0;
    llama_batch*   _batch = nullptr;

    std::vector<llama_chat_message> _messages;
    std::vector<char> _formattedMessages;
    std::vector<llama_token> _promptTokens;
    const char* _chatTemplate = nullptr;
    std::string _ownedChatTemplate;
    std::string _response;
    std::string _cacheResponseTokens;
    bool _storeChats = true;
    int64_t _responseGenerationTime = 0;
    long _responseNumTokens = 0;
    int _nCtxUsed = 0;

    bool _isValidUtf8(const char* response);
    void clearMessagesInternal();

public:
    void loadModel(const char* modelPath, float minP, float temperature, bool storeChats, long contextSize,
                   const char* chatTemplate, int nThreads, int nBatch, bool useMmap, bool useMlock);
    void addChatMessage(const char* message, const char* role);
    void clearMessages();
    float getResponseGenerationSpeed() const;
    int getContextSizeUsed() const;
    bool startCompletion(const char* query);
    std::string completionLoop();
    void stopCompletion();
    void setTemperature(float temperature);
    ~LLMInference();
};
