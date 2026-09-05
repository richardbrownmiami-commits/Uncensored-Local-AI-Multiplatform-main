import 'dart:async';
import 'dart:io';
import 'package:get/get.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'wakelock_service.dart';
import 'chat_storage_service.dart';
import 'log_service.dart';

class LlmService extends GetxService {
  LlamaEngine? _engine;
  LlamaBackend? _backend;

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
  StreamSubscription? _generateSub;

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
    final isLiteRt = filename.toLowerCase().endsWith('.litertlm');

    if (isLiteRt) {
      throw UnsupportedError('LiteRT-LM (.litertlm) is not supported by this Android build. Use a .gguf model.');
    }

    log?.info('Loading model: $filename', source: 'LLM');
    loadingStatusMsg.value = 'Validating GGUF file...';
    loadingProgress.value = 0.0;
    try {
      final handle = await file.open(mode: FileMode.read);
      final magic = await handle.read(8);
      await handle.close();
      if (magic.length < 4 || String.fromCharCodes(magic.sublist(0, 4)) != 'GGUF') {
        throw Exception('File does not have valid GGUF format signature.');
      }
    } catch (e) {
      throw Exception('Invalid or corrupted GGUF file: "$filename". Error: $e');
    }

    _loadingCancelled = false;
    isLoadingModel.value = true;
    loadingProgress.value = 0.05;
    loadingStatusMsg.value = 'Preparing...';

    WakelockService? wakelockService;
    try { wakelockService = Get.find<WakelockService>(); } catch (_) {}
    if (_engine != null || isLoaded.value) {
      loadingStatusMsg.value = 'Unloading previous model...';
      await _fullTeardown();
      await Future.delayed(const Duration(milliseconds: 300));
      if (_loadingCancelled) { _resetLoadingState(); return; }
    }

    try {
      _backend = LlamaBackend();
      _engine = LlamaEngine(_backend!);
    } catch (e) {
      _backend = null;
      _engine = null;
      _resetLoadingState();
      throw Exception('Failed to initialize AI engine. Error: $e');
    }

    try {
      final fileSize = await file.length();
      final sizeGb = (fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2);
      final androidSafeMode = Platform.isAndroid;
      final contextSize = androidSafeMode ? 512 : 2048;
      final threads = androidSafeMode ? 2 : (Platform.numberOfProcessors > 4 ? 4 : 0);

      final storage = Get.find<ChatStorageService>();
      GpuBackend parsedBackend;
      switch (storage.backendType) {
        case 'vulkan': parsedBackend = GpuBackend.vulkan; break;
        case 'opencl': parsedBackend = GpuBackend.opencl; break;
        default: parsedBackend = GpuBackend.cpu;
      }
      final params = ModelParams(
        contextSize: contextSize,
        gpuLayers: androidSafeMode ? 0 : storage.gpuLayers,
        preferredBackend: androidSafeMode ? GpuBackend.cpu : parsedBackend,
        numberOfThreads: threads,
        numberOfThreadsBatch: threads,
      );

      log?.info('Runtime config: android=$androidSafeMode cpu=${androidSafeMode ? 'forced' : 'auto'} context=$contextSize threads=$threads gpuLayers=${params.gpuLayers}', source: 'LLM');
      final loadStopwatch = Stopwatch()..start();
      late final Timer loadHeartbeat;
      loadHeartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_loadingCancelled) return;
        loadingProgress.value = 0.20;
        loadingStatusMsg.value = 'Loading $sizeGb GB model... ${loadStopwatch.elapsed.inSeconds}s';
      });
      try {
        await _engine!.loadModel(path, modelParams: params).timeout(
          const Duration(minutes: 10),
          onTimeout: () => throw TimeoutException('Model loading timed out after 10 minutes.'),
        );
      } finally {
        loadHeartbeat.cancel();
        loadStopwatch.stop();
      }

      if (_loadingCancelled) { await _fullTeardown(); _resetLoadingState(); return; }

      visionSupported.value = false;
      final entities = await file.parent.list().toList();
      final files = entities.whereType<File>().toList();
      final stem = p.basenameWithoutExtension(filename).toLowerCase();
      final named = files.where((f) {
        final n = p.basename(f.path).toLowerCase();
        return n.contains('mmproj') && n.endsWith('.gguf') && (n.contains('qwen3.5') || n.contains(stem));
      }).toList();
      final generic = files.where((f) {
        final n = p.basename(f.path).toLowerCase();
        return n.contains('mmproj') && n.endsWith('.gguf');
      }).toList();
      final candidates = named.isNotEmpty ? named : (generic.length == 1 ? generic : <File>[]);
      if (candidates.isNotEmpty) {
        try {
          loadingStatusMsg.value = 'Loading vision projector...';
          await _engine!.loadMultimodalProjector(candidates.first.path);
          visionSupported.value = await _engine!.supportsVision;
          log?.info('Vision projector loaded: ${p.basename(candidates.first.path)}', source: 'LLM');
        } catch (e) {
          log?.error('Vision projector unavailable: $e', source: 'LLM');
        }
      }

      loadingProgress.value = 1.0;
      loadingStatusMsg.value = visionSupported.value ? 'Model ready · Vision ready!' : 'Model ready!';
      isLoaded.value = true;
      loadedModelPath.value = path;
      await wakelockService?.enableForInference(modelName: p.basenameWithoutExtension(path));
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      isLoaded.value = false;
      loadedModelPath.value = '';
      visionSupported.value = false;
      await _fullTeardown();
      final err = e.toString().toLowerCase();
      if (err.contains('memory') || err.contains('alloc') || err.contains('oom')) throw Exception('Not enough RAM to load this model. Try a smaller model.');
      if (err.contains('permission') || err.contains('access') || err.contains('selinux')) throw Exception('File access denied. Import the model through the app and try again.');
      if (err.contains('timeout') || err.contains('timed out')) throw Exception('Model loading timed out. Try SmolLM2-135M first and check the model file.');
      if (Platform.isAndroid && (err.contains('signal 11') || err.contains('segfault'))) throw Exception('Native model loader crashed. Android CPU mode is forced; try SmolLM2-135M to separate runtime problems from model size.');
      rethrow;
    } finally {
      _resetLoadingState();
    }
  }

  void _resetLoadingState() {
    isLoadingModel.value = false;
    loadingProgress.value = 0.0;
    loadingStatusMsg.value = '';
    _loadingCancelled = false;
  }

  static final _stopPatterns = RegExp(r'<\|end\|>|<\|eot_id\|>|<\|endoftext\|>|<\|im_end\|>|<\|im_start\|>|<end_of_turn>|<start_of_turn>|<\|assistant\|>|<\|user\|>|<\|system\|>|<\|pad\|>|</s>|<s>|\[INST\]|\[/INST\]|\[end\]');
  static final _userTurnPattern = RegExp(r'<\|user\|>|<\|im_start\|>\s*user|<start_of_turn>\s*user|\[INST\]');

  Stream<String> generate({required List<Map<String, String>> messages, String? systemPrompt, double temperature = 0.7}) async* {
    if (_engine == null || !isLoaded.value) throw StateError('No model loaded. Call loadModel() first.');
    if (isGenerating.value) throw StateError('Another generation is already in progress.');
    isGenerating.value = true;
    tokensPerSecond.value = 0.0;
    final stopwatch = Stopwatch()..start();
    int tokenCount = 0;
    String buffer = '';
    try {
      final prompt = _buildPrompt(messages, systemPrompt);
      await for (final token in _engine!.generate(prompt)) {
        tokenCount++;
        if (stopwatch.elapsedMilliseconds > 0) tokensPerSecond.value = tokenCount / (stopwatch.elapsedMilliseconds / 1000);
        buffer += token;
        if (_userTurnPattern.hasMatch(buffer)) {
          final cleaned = buffer.replaceAll(_stopPatterns, '').replaceAll(_userTurnPattern, '').trim();
          if (cleaned.isNotEmpty) yield cleaned;
          break;
        }
        if (_stopPatterns.hasMatch(buffer)) {
          final cleaned = buffer.replaceAll(_stopPatterns, '').trim();
          if (cleaned.isNotEmpty) yield cleaned;
          break;
        }
        if (buffer.length > 40) {
          yield buffer.substring(0, buffer.length - 30);
          buffer = buffer.substring(buffer.length - 30);
        }
      }
      if (buffer.isNotEmpty) {
        final cleaned = buffer.replaceAll(_stopPatterns, '').replaceAll(_userTurnPattern, '').trim();
        if (cleaned.isNotEmpty) yield cleaned;
      }
    } finally {
      stopwatch.stop();
      lastGenerationTokens.value = tokenCount;
      lastGenerationSpeed.value = tokensPerSecond.value;
      isGenerating.value = false;
    }
  }

  Stream<String> generateChatCompletion({required List<LlamaChatMessage> messages, GenerationParams params = const GenerationParams()}) async* {
    if (_engine == null || !isLoaded.value) throw StateError('No model loaded. Call loadModel() first.');
    if (isGenerating.value) throw StateError('Another generation is already in progress.');
    isGenerating.value = true;
    tokensPerSecond.value = 0.0;
    final stopwatch = Stopwatch()..start();
    int tokenCount = 0;
    try {
      await for (final chunk in _engine!.create(messages, params: params, toolChoice: ToolChoice.none)) {
        final choice = chunk.choices.isNotEmpty ? chunk.choices.first : null;
        final content = choice?.delta.content;
        if (content == null || content.isEmpty) continue;
        tokenCount++;
        if (stopwatch.elapsedMilliseconds > 0) tokensPerSecond.value = tokenCount / (stopwatch.elapsedMilliseconds / 1000);
        yield content;
      }
    } finally {
      stopwatch.stop();
      lastGenerationTokens.value = tokenCount;
      lastGenerationSpeed.value = tokensPerSecond.value;
      isGenerating.value = false;
    }
  }

  Future<int> countTokens(String text) async {
    if (_engine == null || !isLoaded.value) return 0;
    try { return await _engine!.getTokenCount(text); } catch (_) { return 0; }
  }

  Future<void> stopGeneration() async {
    _generateSub?.cancel();
    _generateSub = null;
    _engine?.cancelGeneration();
    isGenerating.value = false;
  }

  Future<void> _fullTeardown() async {
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
