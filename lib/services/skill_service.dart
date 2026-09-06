import 'package:get/get.dart';

import '../models/ai_skill.dart';
import 'llm_service.dart';
import 'tool_parser.dart';
import 'tool_service.dart';

class SkillService extends GetxService {
  final skills = AiSkill.builtIns.obs;
  final selectedSkillId = 'general'.obs;
  final enabledToolKinds = <ToolKind>{}.obs;

  AiSkill get selectedSkill => skills.firstWhere(
        (skill) => skill.id == selectedSkillId.value,
        orElse: () => AiSkill.builtIns.first,
      );

  void selectSkill(String id) => selectedSkillId.value = id;

  void setToolEnabled(ToolKind kind, bool enabled) {
    final next = {...enabledToolKinds};
    if (enabled) {
      next.add(kind);
    } else {
      next.remove(kind);
    }
    enabledToolKinds.value = next;
  }

  String buildSystemPrompt({required String customPrompt, required String injectedContext}) {
    final sections = <String>[];
    if (selectedSkill.systemPrompt.trim().isNotEmpty) {
      sections.add('SKILL:\n${selectedSkill.systemPrompt.trim()}');
    }
    if (customPrompt.trim().isNotEmpty) {
      sections.add('USER SYSTEM INSTRUCTIONS:\n${customPrompt.trim()}');
    }
    if (injectedContext.trim().isNotEmpty) {
      sections.add('INJECTED CONTEXT:\n${injectedContext.trim()}');
    }
    if (enabledToolKinds.isNotEmpty) {
      sections.add(ToolParser.toolInstructions);
    }
    return sections.join('\n\n');
  }

  Future<String> runToolAndInject(ToolRequest request) async {
    final tool = Get.find<ToolService>();
    final result = await tool.executeTool(request);
    return result ?? '';
  }

  Future<String> runPrompt({
    required String prompt,
    String customSystemPrompt = '',
    String injectedContext = '',
    double temperature = 0.7,
  }) async {
    final llm = Get.find<LlmService>();
    if (!llm.isLoaded.value) {
      throw StateError('Load a GGUF model before using the Prompt Window.');
    }

    final systemPrompt = buildSystemPrompt(
      customPrompt: customSystemPrompt,
      injectedContext: injectedContext,
    );
    final buffer = StringBuffer();
    await for (final token in llm.generate(
      messages: [
        {'role': 'user', 'content': prompt},
      ],
      systemPrompt: systemPrompt,
      temperature: temperature,
    )) {
      buffer.write(token);
    }
    return buffer.toString();
  }
}
