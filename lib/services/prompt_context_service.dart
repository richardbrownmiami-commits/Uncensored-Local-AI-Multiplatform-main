import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'chat_storage_service.dart';
import 'tool_parser.dart';

/// Loads bundled AI core files and overlays editable on-device copies.
class PromptContextService extends GetxService {
  static const _base = 'assets/ai';
  static const coreFileNames = <String>[
    'soul.md',
    'identity.md',
    'SKILLS.md',
    'TOOLS.md',
    'MEMORY.md',
    'PROMPT.md',
    'MODEL_CONFIG.json',
  ];

  String soul = '';
  String identity = '';
  String skills = '';
  String tools = '';
  String prompt = '';
  String memorySeed = '';
  Map<String, dynamic> modelConfig = const {};
  bool ready = false;

  Future<PromptContextService> init() async {
    final storage = Get.find<ChatStorageService>();
    soul = await _effective('soul.md', storage);
    identity = await _effective('identity.md', storage);
    skills = await _effective('SKILLS.md', storage);
    tools = await _effective('TOOLS.md', storage);
    prompt = await _effective('PROMPT.md', storage);
    memorySeed = await _effective('MEMORY.md', storage);
    final config = await _effective('MODEL_CONFIG.json', storage);
    try {
      modelConfig = jsonDecode(config) as Map<String, dynamic>;
    } catch (_) {
      modelConfig = const {};
    }
    ready = true;
    return this;
  }

  Future<String> _loadBundled(String name) async {
    try {
      return await rootBundle.loadString('$_base/$name');
    } catch (_) {
      return '';
    }
  }

  Future<String> _effective(String name, ChatStorageService storage) async {
    final override = storage.getAiCoreFile(name).trim();
    return override.isNotEmpty ? override : await _loadBundled(name);
  }

  Future<void> saveCoreFile(String name, String value) async {
    await Get.find<ChatStorageService>().setAiCoreFile(name, value);
    await init();
  }

  Future<void> resetCoreFile(String name) async {
    await Get.find<ChatStorageService>().resetAiCoreFile(name);
    await init();
  }

  String currentCoreFile(String name) {
    switch (name) {
      case 'soul.md': return soul;
      case 'identity.md': return identity;
      case 'SKILLS.md': return skills;
      case 'TOOLS.md': return tools;
      case 'MEMORY.md': return memorySeed;
      case 'PROMPT.md': return prompt;
      case 'MODEL_CONFIG.json': return jsonEncode(modelConfig);
      default: return '';
    }
  }

  bool hasOverride(String name) => Get.find<ChatStorageService>().getAiCoreFile(name).trim().isNotEmpty;

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
    if (selectedSkill.trim().isNotEmpty) add('SELECTED SKILL', selectedSkill);
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

    if (includeTools) add('TOOLS', '$tools\n\n${ToolParser.toolInstructions}');
    return sections.join('\n\n');
  }
}
