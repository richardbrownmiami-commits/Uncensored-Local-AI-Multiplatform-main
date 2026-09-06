import 'dart:async';
import 'dart:io';
import 'package:get/get.dart';
import 'package:fcllama/fllama.dart';
import 'package:fcllama/fllama_type.dart' as fcllama_types;
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'wakelock_service.dart';
import 'chat_storage_service.dart';
import 'log_service.dart';

/// Local LLM service.
///
/// Android armeabi-v7a deliberately uses FCLlama's direct llama.cpp binding.
/// The llamadart native runtime currently documents Android arm64-v8a/x86_64
/// as its tested Android architectures, while FCLlama explicitly supports
/// armeabi-v7a. Desktop/iOS paths keep the existing llamadart implementation.
class LlmService extends GetxService {
  LlamaEngine? _engine;
  LlamaBackend? _backend;
  double? _androidContextId;
  StreamSubscription? _androidEvents;
  bool get _useAndroidFcllama => Platform.isAndroid;

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

  void cancelLoading() {
    _loadingCancelled = true;
    try {
      if (_androidContextId != null) FCllama.instance()?.releaseContext(_androidContextId!);
    } catch (_) {}
  }

  Future<void> loadModel(String path) async {
    LogService? log;
    try { log = Get.find<LogService>(); } catch (_) {}
    final file = File(path);
    if (!await file.exists()) throw Exception('Model file not found: $path');
    final filename = p.basename(path);
    if (filename.toLowerCase().endsWith('.litertlm')) {
      throw UnsupportedError('LiteRT-LM (.litertlm) is not supported by this Android build. Use a .gguf model.');
    }

    loadingStatusMsg.value = 'Validating GGUF file...';
    loadingProgress.value = 0.0;
    final handle = await file.open(mode: FileMode.read);
    final magic = await handle.read(8);
    await handle.close();
    if (magic.length < 4 || String.fromCharCodes(magic.sublist(0, 4)) != 'GGUF') {
      throw Exception('Invalid or corrupted GGUF file: "$filename".');
    }

    _loadingCancelled = false;
    isLoadingModel.value = true;
    isLoaded.value = false;
    loadingProgress.value = 0.05;
    loadingStatusMsg.value = 'Preparing $filename...';

    if (_engine != null || _androidContextId != null || isLoaded.value) {
      await _fullTeardown();
      await Future.delayed(const Duration(milliseconds: 200));
    }

    try {
      final fileSize = await file.length();
      final sizeMb = fileSize / (1024 * 1024);
      log?.info('Loading $filename (${sizeMb.toStringAsFixed(1)} MB)', source: 'LLM');

      if (_useAndroidFcllama) {
        await _loadAndroidFcllama(path, filename, log);
      } else {
        await _loadLlamadart(path, filename, log);
      }

      if (_loadingCancelled) {
        await _fullTeardown();
        _resetLoadingState();
        return;
      }

      loadingProgress.value = 1.0;
      loadingStatusMsg.value = 'Model ready!';
      isLoaded.value = true;
      loadedModelPath.value = path;
      await _enableWakelock(filename);
      await Future.delayed(const Duration(milliseconds: 150));
    } catch (e) {
      await _fullTeardown();
      final err = e.toString().toLowerCase();
      if (err.contains('memory') || err.contains('alloc') || err.contains('oom')) {
        throw Exception('Not enough RAM to load this GGUF. On 1 GB RAM, start with a model around 200–400 MB and context 256–512.');
      }
      if (err.contains('permission') || err.contains('access') || err.contains('selinux')) {
        throw Exception('File access denied. Import the GGUF through the app and try again.');
      }
      if (err.contains('timeout') || err.contains('timed out')) {
        throw Exception('Model loading timed out. Try a smaller GGUF such as SmolLM2-135M first.');
      }
      rethrow;
    } finally {
      _resetLoadingState();
    }
  }

  Future<void> _loadAndroidFcllama(String path, String filename, LogService? log) async {
    final llama = FCllama.instance();
    if (llama == null) throw Exception('ARMv7 llama.cpp engine is unavailable.');

    await _androidEvents?.cancel();
    _androidEvents = llama.onTokenStream?.listen((event) {
      final fn = event['function']?.toString();
      if (fn == 'loadProgress') {
        final raw = event['result'];
        final progress = raw is num ? raw.toDouble() : double.tryParse('$raw');
        if (progress != null) {
          loadingProgress.value = (progress / 100.0).clamp(0.05, 0.95);
          loadingStatusMsg.value = 'Loading $filename... ${progress.toStringAsFixed(0)}%';
        }
      }
    });

    loadingStatusMsg.value = 'Starting ARMv7 llama.cpp CPU engine...';
    log?.info('ARMv7 backend: FCLlama / llama.cpp, CPU, mmap=false, mlock=false, context=256, batch=128, threads=2', source: 'LLM');

    // Keep the baseline deliberately conservative for 32-bit address space.
    // A ~200 MB GGUF must leave room for tokenizer metadata, KV cache, Flutter,
    // and Android itself on a 1 GB device.
    final result = await llama.initContext(
      path,
      nCtx: 256,
      nBatch: 128,
      nThreads: 2,
      nGpuLayers: 0,
      useMlock: false,
      useMmap: false,
      emitLoadProgress: true,
    ).timeout(const Duration(minutes: 10));

    if (result == null) throw Exception('ARMv7 llama.cpp returned no context.');
    final id = result['contextId'] ?? result['context_id'];
    if (id == null) throw Exception('ARMv7 llama.cpp failed to create a context: $result');
    _androidContextId = id is num ? id.toDouble() : double.tryParse('$id');
    if (_androidContextId == null || _androidContextId! <= 0) throw Exception('Invalid ARMv7 llama.cpp context id: $id');
    loadingProgress.value = 0.95;
    loadingStatusMsg.value = 'Finalizing model...';
  }

  Future<void> _loadLlamadart(String path, String filename, LogService? log) async {
    _backend = LlamaBackend();
    _engine = LlamaEngine(_backend!);
    final storage = Get.find<ChatStorageService>();
    GpuBackend parsedBackend;
    switch (storage.backendType) {
      case 'vulkan': parsedBackend = GpuBackend.vulkan; break;
      case 'opencl': parsedBackend = GpuBackend.opencl; break;
      default: parsedBackend = GpuBackend.cpu;
    }
    final params = ModelParams(
      contextSize: 2048,
      gpuLayers: storage.gpuLayers,
      preferredBackend: parsedBackend,
      numberOfThreads: Platform.numberOfProcessors > 4 ? 4 : 0,
      useMmap: true,
      useMlock: false,
    );
    log?.info('Runtime config: llamadart desktop/native backend, context=2048 mmap=true', source: 'LLM');
    loadingStatusMsg.value = 'Loading $filename...';
    await _engine!.loadModel(path, modelParams: params).timeout(const Duration(minutes: 10));
  }

  Future<void> _enableWakelock(String filename) async {
    try { await Get.find<WakelockService>().enableForInference(modelName: p.basenameWithoutExtension(filename)); } catch (_) {}
  }

  Stream<String> generate({required List<Map<String, String>> messages, String? systemPrompt, double temperature = 0.7}) async* {
    if (!isLoaded.value) throw StateError('No model loaded. Call loadModel() first.');
    if (isGenerating.value) throw StateError('Another generation is already in progress.');
    isGenerating.value = true;
    tokensPerSecond.value = 0.0;
    final stopwatch = Stopwatch()..start();
    int tokenCount = 0;
    try {
      if (_useAndroidFcllama) {
        final contextId = _androidContextId;
        if (contextId == null) throw StateError('ARMv7 llama.cpp context is missing.');
        final prompt = await _androidPrompt(contextId, messages, systemPrompt);
        final controller = StreamController<String>();
        StreamSubscription? sub;
        sub = FCllama.instance()?.onTokenStream?.listen((event) {
          if (event['function']?.toString() != 'completion') return;
          final result = event['result'];
          if (result is Map && result['token'] is String) controller.add(result['token'] as String);
        });
        try {
          final completion = FCllama.instance()!.completion(
            contextId,
            prompt: prompt,
            temperature: temperature,
            nThreads: 2,
            nPredict: 256,
            topK: 40,
            topP: 0.95,
            minP: 0.05,
            stop: const ['<|end|>', '<|eot_id|>', '<|im_end|>', '</s>'],
            emitRealtimeCompletion: true,
          );
          final resultFuture = completion;
          await for (final token in controller.stream) {
            tokenCount++;
            if (stopwatch.elapsedMilliseconds > 0) tokensPerSecond.value = tokenCount / (stopwatch.elapsedMilliseconds / 1000);
            yield token;
          }
          await resultFuture;
        } finally {
          await sub?.cancel();
          await controller.close();
        }
      } else {
        final prompt = _buildPrompt(messages, systemPrompt);
        await for (final token in _engine!.generate(prompt)) {
          tokenCount++;
          if (stopwatch.elapsedMilliseconds > 0) tokensPerSecond.value = tokenCount / (stopwatch.elapsedMilliseconds / 1000);
          yield token;
        }
      }
    } finally {
      stopwatch.stop();
      lastGenerationTokens.value = tokenCount;
      lastGenerationSpeed.value = tokensPerSecond.value;
      isGenerating.value = false;
    }
  }

  Future<String> _androidPrompt(double contextId, List<Map<String, String>> messages, String? systemPrompt) async {
    try {
      final roleMessages = <fcllama_types.RoleContent>[];
      if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
        roleMessages.add(fcllama_types.RoleContent(role: 'system', content: systemPrompt));
      }
      for (final msg in messages) {
        roleMessages.add(fcllama_types.RoleContent(role: msg['role'] ?? 'user', content: msg['content'] ?? ''));
      }
      final formatted = await FCllama.instance()?.getFormattedChat(contextId, messages: roleMessages);
      if (formatted != null && formatted.isNotEmpty) return '$formatted<|assistant|>';
    } catch (_) {}
    return _buildPrompt(messages, systemPrompt);
  }

  Stream<String> generateChatCompletion({required List<LlamaChatMessage> messages, GenerationParams params = const GenerationParams()}) async* {
    // The controller currently uses generate(). Keep this API for desktop
    // callers and route Android through the same safe text-generation path.
    final mapped = messages.map((m) => <String, String>{'role': m.role.name, 'content': m.content ?? ''}).toList();
    yield* generate(messages: mapped);
  }

  Future<int> countTokens(String text) async {
    if (!isLoaded.value) return 0;
    if (_useAndroidFcllama && _androidContextId != null) {
      try {
        final result = await FCllama.instance()!.tokenize(_androidContextId!, text: text);
        final tokens = result?['tokens'];
        if (tokens is List) return tokens.length;
      } catch (_) {}
      return 0;
    }
    try { return await _engine!.getTokenCount(text); } catch (_) { return 0; }
  }

  Future<void> stopGeneration() async {
    if (_useAndroidFcllama && _androidContextId != null) {
      try { await FCllama.instance()?.stopCompletion(contextId: _androidContextId!); } catch (_) {}
    } else {
      _engine?.cancelGeneration();
    }
    isGenerating.value = false;
  }

  Future<void> _fullTeardown() async {
    await _androidEvents?.cancel();
    _androidEvents = null;
    if (_androidContextId != null) {
      try { await FCllama.instance()?.releaseContext(_androidContextId!); } catch (_) {}
      _androidContextId = null;
    }
    if (_engine != null) {
      try { await _engine!.dispose(); } catch (_) {}
      _engine = null;
    }
    _backend = null;
    isLoaded.value = false;
    loadedModelPath.value = '';
    visionSupported.value = false;
    tokensPerSecond.value = 0.0;
  }

  Future<void> unloadModel() async {
    await _fullTeardown();
    try { await Get.find<WakelockService>().disable(); } catch (_) {}
  }

  void _resetLoadingState() {
    isLoadingModel.value = false;
    loadingProgress.value = 0.0;
    loadingStatusMsg.value = '';
    _loadingCancelled = false;
  }

  String _buildPrompt(List<Map<String, String>> messages, String? systemPrompt) {
    final buffer = StringBuffer();
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      buffer.writeln('<|system|>');
      buffer.writeln(systemPrompt);
      buffer.writeln('<|end|>');
    }
    for (final msg in messages) {
      buffer.writeln('<|${msg['role'] ?? 'user'}|>');
      buffer.writeln(msg['content'] ?? '');
      buffer.writeln('<|end|>');
    }
    buffer.writeln('<|assistant|>');
    return buffer.toString();
  }

  @override
  void onClose() {
    unloadModel();
    super.onClose();
  }
}
