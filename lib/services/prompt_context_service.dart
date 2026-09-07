import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'chat_storage_service.dart';
import 'tool_parser.dart';

/// Loads the bundled AI identity/prompt/skill/tool/memory files and turns them
/// into runtime context injected into every model generation.
class PromptContextService extends GetxService {
  static const _base = 'assets/ai';

  String soul = '';
  String identity = '';
  String skills = '';
  String tools = '';
  String prompt = '';
  String memorySeed = '';
  Map<String, dynamic> modelConfig = const {};
  bool ready = false;

  Future<PromptContextService> init() async {
    soul = await _load('soul.md');
    identity = await _load('identity.md');
    skills = await _load('SKILLS.md');
    tools = await _load('TOOLS.md');
    prompt = await _load('PROMPT.md');
    memorySeed = await _load('MEMORY.md');
    final config = await _load('MODEL_CONFIG.json');
    try {
      modelConfig = jsonDecode(config) as Map<String, dynamic>;
    } catch (_) {
      modelConfig = const {};
    }
    ready = true;
    return this;
  }

  Future<String> _load(String name) async {
    try {
      return await rootBundle.loadString('$_base/$name');
    } catch (_) {
      return '';
    }
  }

  String buildInjection({
    required String modelFilename,
    required int contextSize,
    required int threads,
    required int batch,
    String selectedSkill = '',
    String userMemory = '',
    bool includeTools = true,
  }) {
    final storage = Get.find<ChatStorageService>();
    final sections = <String>[];
    void add(String title, String value) {
      if (value.trim().isNotEmpty) sections.add('[$title]\n${value.trim()}');
    }

    add('IDENTITY', identity);
    add('SOUL', soul);
    add('PROMPT PIPELINE', prompt);
    if (selectedSkill.trim().isNotEmpty) {
      add('SELECTED SKILL', selectedSkill);
    }
    final memory = userMemory.trim().isNotEmpty ? userMemory : memorySeed;
    add('MEMORY', memory);

    final runtime = jsonEncode({
      'model': modelFilename,
      'engine': modelConfig['engine'] ?? 'native-smolchat-llama.cpp',
      'format': modelConfig['format'] ?? 'GGUF',
      'context': contextSize,
      'threads': threads,
      'batch': batch,
      'gpuLayers': storage.gpuLayers,
      'cpuOnly': true,
    });
    add('MODEL CONFIG', runtime);

    if (includeTools) {
      add('TOOLS', '$tools\n\n${ToolParser.toolInstructions}');
    }
    return sections.join('\n\n');
  }
}
