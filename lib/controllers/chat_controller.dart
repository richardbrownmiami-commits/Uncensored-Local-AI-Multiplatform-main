import 'dart:async';
import 'package:get/get.dart';
import 'package:llamadart/llamadart.dart';

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
  final Rxn<ToolRequest> pendingAction = Rxn<ToolRequest>();
  final RxnString lastToolResult = RxnString();
  final toolsEnabled = true.obs;
  StreamSubscription<String>? _genSub;

  @override
  void onInit() {
    super.onInit();
    _loadChats();
    temperature.value = _storage.defaultTemperature;
    systemPrompt.value = _storage.globalSystemPrompt;
  }

  void _loadChats() => chats.value = _storage.getAllChats();

  ChatModel? get activeChat {
    if (activeChatId.value == null) return null;
    try { return chats.firstWhere((c) => c.id == activeChatId.value); } catch (_) { return null; }
  }

  void newChat() {
    final chat = ChatModel(id: DateTime.now().millisecondsSinceEpoch.toString(), systemPrompt: systemPrompt.value);
    chats.insert(0, chat);
    _storage.saveChat(chat);
    activeChatId.value = chat.id;
  }

  void switchChat(String id) {
    activeChatId.value = id;
    final chat = activeChat;
    if (chat != null) systemPrompt.value = chat.systemPrompt;
  }

  void deleteChat(String id) {
    chats.removeWhere((c) => c.id == id);
    _storage.deleteChat(id);
    if (activeChatId.value == id) activeChatId.value = chats.isNotEmpty ? chats.first.id : null;
  }

  /// Sends normal text or a multimodal image+text turn.
  Future<void> sendMessage(String text, {String? modelFilename, String? imagePath}) async {
    if (text.trim().isEmpty && imagePath == null) return;
    final chat = activeChat;
    if (chat == null) return;

    final userContent = text.trim().isEmpty ? '🖼️ Image attached' : text.trim();
    final userMsg = MessageModel(role: MessageRole.user, content: userContent);
    chat.messages.add(userMsg);
    chat.autoTitle();
    chat.updatedAt = DateTime.now();
    if (chat.modelId.isEmpty && modelFilename != null) chat.modelId = modelFilename;
    _storage.saveChat(chat);
    chats.refresh();

    final history = chat.messages
        .where((m) => !m.isSystem)
        .map((m) => m.toLlamaMessage())
        .toList();

    isGenerating.value = true;
    streamedResponse.value = '';
    final aiMsg = MessageModel(role: MessageRole.assistant, content: '');
    chat.messages.add(aiMsg);
    chats.refresh();

    try {
      final baseSystemPrompt = chat.systemPrompt.isNotEmpty ? chat.systemPrompt : systemPrompt.value;
      final toolInstructions = toolsEnabled.value && (_github.isConfigured || _hasLocalTools)
          ? '\n\n${ToolParser.toolInstructions}'
          : '';
      final effectiveSystemPrompt = '$baseSystemPrompt$toolInstructions';

      late final Stream<String> stream;
      if (imagePath != null) {
        // Image turns use the typed llamadart content API. The persisted
        // current user text is excluded because the multimodal method adds
        // the image+prompt as the actual current turn.
        final visionHistory = <LlamaChatMessage>[
          if (effectiveSystemPrompt.isNotEmpty)
            LlamaChatMessage.fromText(role: LlamaChatRole.system, text: effectiveSystemPrompt),
          ...chat.messages
              .where((m) => !m.isSystem && m != userMsg && m != aiMsg)
              .map((m) => LlamaChatMessage.fromText(
                    role: m.isUser ? LlamaChatRole.user : LlamaChatRole.assistant,
                    text: m.content,
                  )),
        ];
        stream = _llm.generateMultimodalCompletion(
          messages: visionHistory,
          imagePath: imagePath,
          prompt: text.trim().isEmpty ? 'Describe this image.' : text.trim(),
        );
      } else {
        stream = _llm.generate(
          messages: history,
          systemPrompt: effectiveSystemPrompt,
          temperature: temperature.value,
        );
      }

      await for (final token in stream) {
        streamedResponse.value += token;
        aiMsg.content = streamedResponse.value;
        chats.refresh();
      }
    } catch (e) {
      if (aiMsg.content.isEmpty) aiMsg.content = '⚠ Error: ${e.toString()}';
    } finally {
      aiMsg.content = aiMsg.content
          .replaceAll(RegExp(
            r'<\|end\|>|<\|eot_id\|>|<\|endoftext\|>|<\|im_end\|>|<\|im_start\|>'
            r'|<end_of_turn>|<start_of_turn>|<\|assistant\|>|<\|user\|>|<\|system\|>'
            r'|<\|pad\|>|</s>|<s>|\[INST\]|\[/INST\]|\[end\]'
          ), '')
          .trim();

      if (toolsEnabled.value) {
        final request = ToolParser.parse(aiMsg.content);
        aiMsg.content = ToolParser.stripToolBlocks(aiMsg.content);
        if (request.kind != ToolKind.none) _logToolUsage(request);

        if (_github.isConfigured) {
          switch (request.kind) {
            case ToolKind.githubWriteFile:
              pendingAction.value = request;
              return;
            case ToolKind.githubReadFile:
              try {
                final fileContent = await _github.readFile(request.path!);
                aiMsg.content += '\n\n---\n**GitHub ${request.path}:**\n```\n$fileContent\n```';
              } catch (e) {
                aiMsg.content += '\n\n⚠ Could not read GitHub file: $e';
              }
              break;
            case ToolKind.githubListIssues:
              try {
                final issues = await _github.listIssues();
                final summary = issues.isEmpty ? 'No open issues.' : issues.map((i) => '- #${i['number']}: ${i['title']}').join('\n');
                aiMsg.content += '\n\n---\n**GitHub Open Issues:**\n$summary';
              } catch (e) {
                aiMsg.content += '\n\n⚠ Could not list GitHub issues: $e';
              }
              break;
            default:
              break;
          }
        }

        if (request.kind != ToolKind.none && !request.requiresConfirmation) {
          try {
            final result = await _toolService.executeTool(request);
            if (result != null && result.isNotEmpty) aiMsg.content += '\n\n---\n**Tool Result:**\n$result';
          } catch (e) {
            aiMsg.content += '\n\n⚠ Tool error: $e';
          }
        } else if (request.requiresConfirmation) {
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

  Future<String?> approvePendingAction() async {
    final action = pendingAction.value;
    if (action == null) return null;
    pendingAction.value = null;
    try {
      if (action.kind == ToolKind.githubWriteFile) {
        await _github.commitFile(path: action.path!, content: action.content ?? '', commitMessage: action.message ?? 'update via AI chat');
        return null;
      }
      if (action.kind == ToolKind.writeFile || action.kind == ToolKind.clipboardCopy) {
        await _toolService.executeConfirmedTool(action);
        return null;
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  void rejectPendingAction() => pendingAction.value = null;
  bool get _hasLocalTools => true;
  void _logToolUsage(ToolRequest request) {}
  void toggleTools(bool enabled) => toolsEnabled.value = enabled;
  void stopGeneration() { _llm.stopGeneration(); isGenerating.value = false; }

  void updateSystemPrompt(String prompt) {
    systemPrompt.value = prompt;
    final chat = activeChat;
    if (chat != null) { chat.systemPrompt = prompt; _storage.saveChat(chat); }
  }

  void setGlobalSystemPrompt(String prompt) {
    systemPrompt.value = prompt;
    _storage.globalSystemPrompt = prompt;
  }

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
