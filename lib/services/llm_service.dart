import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'wakelock_service.dart';
import 'chat_storage_service.dart';
import 'log_service.dart';

/// Local LLM service. Android uses Flutter -> Kotlin JNI -> C++ llama.cpp -> GGUF,
/// following the native architecture used by SmolChat.
class LlmService extends GetxService {
  static const MethodChannel _native = MethodChannel('portable_ai/native_llama');
  LlamaEngine? _engine;
  LlamaBackend? _backend;
  bool get _useNativeAndroid => Platform.isAndroid;

  final isLoaded = false.obs;
  final isGenerating = false.obs;
  final loadedModelPath = ''.obs;
  final tokensPerSecond = 0.0.obs;
  final lastGenerationTokens = 0.obs;
  final lastGenerationSpeed = 0.0.obs;
  final visionSupported = false.obs;
  final isLoadingModel = false.obs;
  final loadingProgress = 0.0.obs;
  final loadingStatusMsg = ''.obs;
  bool _loadingCancelled = false;

  String get loadedModelFilename => loadedModelPath.value.isEmpty ? '' : p.basename(loadedModelPath.value);
  String get publicModelId {
    final filename = loadedModelFilename;
    if (filename.isEmpty) return 'local';
    final stem = filename.toLowerCase().endsWith('.gguf') ? filename.substring(0, filename.length - 5) : p.basenameWithoutExtension(filename);
    return stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-|-$'), '');
  }
  bool get isLiteRtLm => loadedModelFilename.toLowerCase().endsWith('.litertlm');
  Future<LlmService> init() async => this;

  void cancelLoading() => _loadingCancelled = true;

  Future<void> loadModel(String path) async {
    LogService? log;
    try { log = Get.find<LogService>(); } catch (_) {}
    final file = File(path);
    if (!await file.exists()) throw Exception('Model file not found: $path');
    final filename = p.basename(path);
    if (filename.toLowerCase().endsWith('.litertlm')) throw UnsupportedError('LiteRT-LM is not supported by this GGUF engine. Use a .gguf model.');

    final handle = await file.open(mode: FileMode.read);
    final magic = await handle.read(4);
    await handle.close();
    if (magic.length != 4 || String.fromCharCodes(magic) != 'GGUF') throw Exception('Invalid or corrupted GGUF file: "$filename".');

    await unloadModel();
    _loadingCancelled = false;
    isLoadingModel.value = true;
    loadingProgress.value = 0.05;
    loadingStatusMsg.value = 'Loading $filename with native llama.cpp...';
    try {
      final size = await file.length();
      log?.info('Native load: $filename (${(size / (1024 * 1024)).toStringAsFixed(1)} MB)', source: 'LLM');
      if (_useNativeAndroid) {
        final storage = Get.find<ChatStorageService>();
        final context = storage.contextSize.clamp(128, 8192);
        final threads = storage.cpuThreads.clamp(1, 16);
        final batch = storage.batchSize.clamp(32, 1024);
        final raw = await _native.invokeMethod<dynamic>('load', {'path': path, 'context': context, 'threads': threads, 'batch': batch});
        final response = raw is Map ? Map<Object?, Object?>.from(raw) : const <Object?, Object?>{};
        if (response['ok'] != true) throw Exception(response['message']?.toString() ?? 'Native llama.cpp failed to load the GGUF.');
      } else {
        await _loadLlamadart(path, filename, log);
      }
      if (_loadingCancelled) { await unloadModel(); return; }
      loadingProgress.value = 1.0;
      loadingStatusMsg.value = 'Model ready!';
      isLoaded.value = true;
      loadedModelPath.value = path;
      await _enableWakelock(filename);
    } catch (e) {
      await unloadModel();
      throw Exception('GGUF load failed in native llama.cpp: $e');
    } finally {
      isLoadingModel.value = false;
      if (!isLoaded.value) loadingProgress.value = 0.0;
      loadingStatusMsg.value = '';
      _loadingCancelled = false;
    }
  }

  Future<void> _loadLlamadart(String path, String filename, LogService? log) async {
    _backend = LlamaBackend();
    _engine = LlamaEngine(_backend!);
    final storage = Get.find<ChatStorageService>();
    GpuBackend backend;
    switch (storage.backendType) {
      case 'vulkan': backend = GpuBackend.vulkan; break;
      case 'opencl': backend = GpuBackend.opencl; break;
      default: backend = GpuBackend.cpu;
    }
    final params = ModelParams(contextSize: 2048, gpuLayers: storage.gpuLayers, preferredBackend: backend, numberOfThreads: Platform.numberOfProcessors > 4 ? 4 : 0, useMmap: true, useMlock: false);
    log?.info('Runtime config: llamadart desktop/native backend, context=2048 mmap=true', source: 'LLM');
    await _engine!.loadModel(path, modelParams: params).timeout(const Duration(minutes: 10));
  }

  Future<void> _enableWakelock(String filename) async {
    try { await Get.find<WakelockService>().enableForInference(modelName: p.basenameWithoutExtension(filename)); } catch (_) {}
  }

  Stream<String> generate({required List<Map<String, String>> messages, String? systemPrompt, double temperature = 0.7}) async* {
    if (!isLoaded.value) throw StateError('No model loaded. Call loadModel() first.');
    if (isGenerating.value) throw StateError('Another generation is already in progress.');
    isGenerating.value = true;
    final watch = Stopwatch()..start();
    try {
      final prompt = _buildPrompt(messages, systemPrompt);
      if (_useNativeAndroid) {
        final text = await _native.invokeMethod<String>('generate', {'prompt': prompt, 'maxTokens': 256, 'temperature': temperature}) ?? '';
        if (text.startsWith('ERROR:')) throw Exception(text);
        if (text.isNotEmpty) yield text;
      } else {
        await for (final token in _engine!.generate(prompt)) yield token;
      }
    } finally {
      watch.stop();
      isGenerating.value = false;
      lastGenerationSpeed.value = watch.elapsedMilliseconds > 0 ? 0 : 0;
    }
  }

  Stream<String> generateChatCompletion({required List<LlamaChatMessage> messages, GenerationParams params = const GenerationParams()}) async* {
    final mapped = messages.map((m) => <String, String>{'role': m.role.name, 'content': m.content ?? ''}).toList();
    yield* generate(messages: mapped);
  }

  Future<int> countTokens(String text) async {
    if (!isLoaded.value || _useNativeAndroid) return 0;
    try { return await _engine!.getTokenCount(text); } catch (_) { return 0; }
  }

  Future<void> stopGeneration() async {
    if (_useNativeAndroid) {
      try { await _native.invokeMethod('unload'); } catch (_) {}
      isLoaded.value = false;
      loadedModelPath.value = '';
    } else {
      _engine?.cancelGeneration();
    }
    isGenerating.value = false;
  }

  Future<void> unloadModel() async {
    if (_useNativeAndroid) { try { await _native.invokeMethod('unload'); } catch (_) {} }
    if (_engine != null) { try { await _engine!.dispose(); } catch (_) {} _engine = null; }
    _backend = null;
    isLoaded.value = false;
    loadedModelPath.value = '';
    visionSupported.value = false;
    tokensPerSecond.value = 0.0;
  }

  String _buildPrompt(List<Map<String, String>> messages, String? systemPrompt) {
    final b = StringBuffer();
    if (systemPrompt != null && systemPrompt.isNotEmpty) { b.writeln('<|system|>'); b.writeln(systemPrompt); b.writeln('<|end|>'); }
    for (final m in messages) { b.writeln('<|${m['role'] ?? 'user'}|>'); b.writeln(m['content'] ?? ''); b.writeln('<|end|>'); }
    b.writeln('<|assistant|>');
    return b.toString();
  }

  @override
  void onClose() { unloadModel(); super.onClose(); }
}
