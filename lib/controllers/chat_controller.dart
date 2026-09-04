import 'dart:async';
import 'package:get/get.dart';

import '../models/chat_model.dart';
import '../models/message_model.dart';
import '../services/llm_service.dart';
import '../services/chat_storage_service.dart';
import '../services/github_service.dart';
import '../services/tool_parser.dart';
import '../services/tool_service.dart';

class ChatController extends GetxController {
  final LlmService _llm = Get.find<LlmService>();
  final ChatStorageService _storage = Get.find<ChatStorageService>();
  final GitHubService _github = Get.find<GitHubService>();
  final ToolService _toolService = Get.find<ToolService>();

  final chats = <ChatModel>[].obs;
  final activeChatId = RxnString();
  final isGenerating = false.obs;
  final streamedResponse = ''.obs;
  final temperature = 0.7.obs;
  final systemPrompt = ''.obs;

  /// Set when the model's last reply contained a tool request that needs user confirmation.
  /// The chat screen should watch this and show an approve/cancel dialog.
  /// Null means there is nothing pending.
  final Rxn<ToolRequest> pendingAction = Rxn<ToolRequest>();

  /// Result of the most recent read-only tool call, shown inline in the chat.
  /// Null means nothing to show.
  final RxnString lastToolResult = RxnString();
  
  /// Track if tools are enabled (user preference)
  final toolsEnabled = true.obs;

  StreamSubscription<String>? _genSub;

  @override
  void onInit() {
    super.onInit();
    _loadChats();
    temperature.value = _storage.defaultTemperature;
    systemPrompt.value = _storage.globalSystemPrompt;
  }

  void _loadChats() {
    chats.value = _storage.getAllChats();
  }

  ChatModel? get activeChat {
    if (activeChatId.value == null) return null;
    try {
      return chats.firstWhere((c) => c.id == activeChatId.value);
    } catch (_) {
      return null;
    }
  }

  /// Create a new chat and switch to it.
  void newChat() {
    final chat = ChatModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      systemPrompt: systemPrompt.value,
    );
    chats.insert(0, chat);
    _storage.saveChat(chat);
    activeChatId.value = chat.id;
  }

  /// Switch to an existing chat.
  void switchChat(String id) {
    activeChatId.value = id;
    final chat = activeChat;
    if (chat != null) {
      systemPrompt.value = chat.systemPrompt;
    }
  }

  /// Delete a chat.
  void deleteChat(String id) {
    chats.removeWhere((c) => c.id == id);
    _storage.deleteChat(id);
    if (activeChatId.value == id) {
      activeChatId.value = chats.isNotEmpty ? chats.first.id : null;
    }
  }

  /// Send a user message and stream AI response.
  Future<void> sendMessage(String text, {String? modelFilename}) async {
    if (text.trim().isEmpty) return;
    final chat = activeChat;
    if (chat == null) return;

    // Add user message
    final userMsg = MessageModel(role: MessageRole.user, content: text.trim());
    chat.messages.add(userMsg);
    chat.autoTitle();
    chat.updatedAt = DateTime.now();

    // Lock model to this chat on first message
    if (chat.modelId.isEmpty && modelFilename != null) {
      chat.modelId = modelFilename;
    }

    _storage.saveChat(chat);
    chats.refresh();

    // Build message history for LLM
    final history = chat.messages
        .where((m) => !m.isSystem)
        .map((m) => m.toLlamaMessage())
        .toList();

    // Start generation
    isGenerating.value = true;
    streamedResponse.value = '';

    final aiMsg = MessageModel(role: MessageRole.assistant, content: '');
    chat.messages.add(aiMsg);
    chats.refresh();

    try {
      final baseSystemPrompt = chat.systemPrompt.isNotEmpty
          ? chat.systemPrompt
          : systemPrompt.value;
      
      // Add tool instructions if any tools are enabled
      final toolInstructions = toolsEnabled.value && (_github.isConfigured || _hasLocalTools)
          ? '\n\n${ToolParser.toolInstructions}'
          : '';
      final effectiveSystemPrompt = '$baseSystemPrompt$toolInstructions';

      final stream = _llm.generate(
        messages: history,
        systemPrompt: effectiveSystemPrompt,
        temperature: temperature.value,
      );

      await for (final token in stream) {
        streamedResponse.value += token;
        aiMsg.content = streamedResponse.value;
        // Throttle UI refreshes
        chats.refresh();
      }
    } catch (e) {
      if (aiMsg.content.isEmpty) {
        aiMsg.content = '⚠ Error: ${e.toString()}';
      }
    } finally {
      // Clean up any trailing stop tokens or whitespace
      aiMsg.content = aiMsg.content
          .replaceAll(RegExp(
            r'<\|end\|>|<\|eot_id\|>|<\|endoftext\|>|<\|im_end\|>|<\|im_start\|>'
            r'|<end_of_turn>|<start_of_turn>|<\|assistant\|>|<\|user\|>|<\|system\|>'
            r'|<\|pad\|>|</s>|<s>|\[INST\]|\[/INST\]|\[end\]'
          ), '')
          .trim();

      // Detect tool requests in what the model just produced.
      // Read-only actions run immediately and their result is appended to
      // the same message. Write requests are surfaced via pendingAction for
      // the UI to show an approve/cancel dialog.
      if (toolsEnabled.value) {
        final request = ToolParser.parse(aiMsg.content);
        aiMsg.content = ToolParser.stripToolBlocks(aiMsg.content);

        if (request.kind != ToolKind.none) {
          _logToolUsage(request);
        }

        // Handle GitHub tools
        if (_github.isConfigured) {
          switch (request.kind) {
            case ToolKind.githubWriteFile:
              pendingAction.value = request;
              return; // Don't process other tools if waiting for confirmation
            case ToolKind.githubReadFile:
              try {
                final fileContent = await _github.readFile(request.path!);
                aiMsg.content +=
                    '\n\n---\n**GitHub ${request.path}:**\n```\n$fileContent\n```';
              } catch (e) {
                aiMsg.content += '\n\n⚠ Could not read GitHub file: $e';
              }
              break;
            case ToolKind.githubListIssues:
              try {
                final issues = await _github.listIssues();
                final summary = issues.isEmpty
                    ? 'No open issues.'
                    : issues
                        .map((i) => '- #${i['number']}: ${i['title']}')
                        .join('\n');
                aiMsg.content += '\n\n---\n**GitHub Open Issues:**\n$summary';
              } catch (e) {
                aiMsg.content += '\n\n⚠ Could not list GitHub issues: $e';
              }
              break;
            default:
              break;
          }
        }

        // Handle local tools (file system, utilities)
        if (request.kind != ToolKind.none && !request.requiresConfirmation) {
          try {
            final result = await _toolService.executeTool(request);
            if (result != null && result.isNotEmpty) {
              aiMsg.content += '\n\n---\n**Tool Result:**\n$result';
            }
          } catch (e) {
            aiMsg.content += '\n\n⚠ Tool error: $e';
          }
        } else if (request.requiresConfirmation) {
          // Write operations need user approval
          pendingAction.value = request;
        }
      }

      isGenerating.value = false;
      streamedResponse.value = '';
      chat.updatedAt = DateTime.now();
      _storage.saveChat(chat);
      chats.refresh();
    }
  }

  /// Called only from the user tapping "Approve" on the pending-action
  /// dialog. This is the single place in the app that executes confirmed tools.
  Future<String?> approvePendingAction() async {
    final action = pendingAction.value;
    if (action == null) return null;
    pendingAction.value = null;
    
    try {
      // Handle GitHub write
      if (action.kind == ToolKind.githubWriteFile) {
        await _github.commitFile(
          path: action.path!,
          content: action.content ?? '',
          commitMessage: action.message ?? 'update via AI chat',
        );
        return null; // null == success
      }
      
      // Handle local write operations
      if (action.kind == ToolKind.writeFile || action.kind == ToolKind.clipboardCopy) {
        final result = await _toolService.executeConfirmedTool(action);
        return null; // success
      }
      
      return null;
    } catch (e) {
      return e.toString(); // non-null == error message to show
    }
  }

  /// Called when the user taps "Cancel" on the pending-action dialog.
  void rejectPendingAction() {
    pendingAction.value = null;
  }
  
  /// Helper to check if local tools are available
  bool get _hasLocalTools => true; // Local tools are always available
  
  /// Helper to log tool usage
  void _logToolUsage(ToolRequest request) {
    // Can be extended to track usage analytics
  }
  
  /// Toggle tools on/off
  void toggleTools(bool enabled) {
    toolsEnabled.value = enabled;
  }

  /// Stop current generation.
  void stopGeneration() {
    _llm.stopGeneration();
    isGenerating.value = false;
  }

  /// Update the system prompt for the active chat.
  void updateSystemPrompt(String prompt) {
    systemPrompt.value = prompt;
    final chat = activeChat;
    if (chat != null) {
      chat.systemPrompt = prompt;
      _storage.saveChat(chat);
    }
  }

  /// Set and persist the global system prompt.
  void setGlobalSystemPrompt(String prompt) {
    systemPrompt.value = prompt;
    _storage.globalSystemPrompt = prompt;
  }

  /// Clear global system prompt.
  void clearGlobalSystemPrompt() {
    systemPrompt.value = '';
    _storage.globalSystemPrompt = '';
  }

  void updateTemperature(double temp) {
    temperature.value = temp;
    _storage.defaultTemperature = temp;
  }

  @override
  void onClose() {
    _genSub?.cancel();
    super.onClose();
  }
}
