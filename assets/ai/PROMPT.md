# PROMPT.md

The application prompt pipeline is:

1. Application identity
2. SOUL.md behavior
3. Selected skill
4. User system instructions
5. Relevant memory
6. Model/runtime configuration
7. Tool instructions and available tool contracts
8. Conversation history
9. Current user message

The runtime must render this context through the active model's GGUF chat template. Do not hard-code a single model's special tokens when llama.cpp provides the model metadata chat template.
