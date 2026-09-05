import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'wakelock_service.dart';
import 'chat_storage_service.dart';
import 'log_service.dart';

/// Wraps llamadart's LlamaEngine for model loading, generation, lifecycle,
/// and the local multimodal path used by supported GGUF/LiteRT-LM models.
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

  String get loadedModelFilename {
    final path = loadedModelPath.value;
    if (path.isEmpty) return '';
    return p.basename(path);
  }

  String get publicModelId {
    final filename = loadedModelFilename;
    if (filename.isEmpty) return 'local';
    final stem = filename.toLowerCase().endsWith('.gguf')
        ? filename.substring(0, filename.length - 5)
        : p.basenameWithoutExtension(filename);
    return stem
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  bool get isLiteRtLm => loadedModelFilename.toLowerCase().endsWith('.litertlm');

  Future<LlmService> init() async => this;

  void cancelLoading() => _loadingCancelled = true;

  /// Load either a GGUF model or a native LiteRT-LM bundle.
  /// GGUF files are validated by magic bytes; LiteRT-LM bundles are passed
  /// directly to llamadart's runtime router.
  Future<void> loadModel(String path) async {
    LogService? log;
    try { log = Get.find<LogService>(); } catch (_) {}

    final file = File(path);
    if (!await file.exists()) {
      log?.error('Model file not found: $path', source: 'LLM');
      throw Exception('Model file not found: $path');
    }

    final filename = p.basename(path);
    final lowerFilename = filename.toLowerCase();
    final isLiteRt = lowerFilename.endsWith('.litertlm');
    log?.info('Loading model: $filename', source: 'LLM');

    loadingStatusMsg.value = isLiteRt ? 'Validating LiteRT-LM bundle...' : 'Validating GGUF file...';
    loadingProgress.value = 0.0;

    if (!isLiteRt) {
      try {
        final randomAccess = await file.open(mode: FileMode.read);
        final magicBytes = await randomAccess.read(8);
        await randomAccess.close();
        if (magicBytes.length < 4 ||
            String.fromCharCodes(magicBytes.sublist(0, 4)) != 'GGUF') {
          throw Exception('File does not have valid GGUF format signature.');
        }
      } catch (e) {
        log?.error('GGUF validation failed: $e', source: 'LLM');
        throw Exception('Invalid or corrupted GGUF file: "$filename". Error: $e');
      }
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
      await Future.delayed(const Duration(milliseconds: 500));
      if (_loadingCancelled) {
        _resetLoadingState();
        return;
      }
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
      final contextSize = Platform.isAndroid ? 1024 : 2048;
      final storage = Get.find<ChatStorageService>();

      GpuBackend parsedBackend;
      switch (storage.backendType) {
        case 'vulkan':
          parsedBackend = GpuBackend.vulkan;
          break;
        case 'opencl':
          parsedBackend = GpuBackend.opencl;
          break;
        default:
          parsedBackend = GpuBackend.cpu;
      }

      final userGpuLayers = storage.gpuLayers;
      final threads = Platform.numberOfProcessors > 4 ? 4 : 0;

      // LiteRT-LM uses its own runtime backend selection. Do not pass
      // llama.cpp-only GPU-layer/backend controls to a .litertlm bundle.
      final params = isLiteRt
          ? ModelParams(numberOfThreads: threads)
          : ModelParams(
              contextSize: contextSize,
              gpuLayers: userGpuLayers,
              preferredBackend: parsedBackend,
              numberOfThreads: threads,
              numberOfThreadsBatch: threads,
            );

      log?.info(
        'Model format=${isLiteRt ? 'LiteRT-LM' : 'GGUF'}, backend=$parsedBackend, '
        'GPU layers=${isLiteRt ? 'runtime-managed' : userGpuLayers}, '
        'ctx=${isLiteRt ? 'runtime-managed' : contextSize}, threads=$threads',
        source: 'LLM',
      );

      final loadStopwatch = Stopwatch()..start();
      Timer? loadHeartbeat;
      loadHeartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_loadingCancelled) return;
        loadingProgress.value = 0.20;
        loadingStatusMsg.value = 'Loading $sizeGb GB model... ${loadStopwatch.elapsed.inSeconds}s';
      });

      try {
        await _engine!.loadModel(path, modelParams: params).timeout(
          const Duration(minutes: 10),
          onTimeout: () => throw TimeoutException(
            'Model loading timed out after 10 minutes. The model may be too large for your device or corrupted.',
          ),
        );
      } finally {
        loadHeartbeat.cancel();
        loadStopwatch.stop();
      }

      if (_loadingCancelled) {
        await _fullTeardown();
        _resetLoadingState();
        return;
      }

      // GGUF vision models need a matching mmproj file. Look for one beside
      // the model; never pretend vision works merely because the filename says
      // "vision". LiteRT-LM bundles use their native media path instead.
      visionSupported.value = false;
      if (isLiteRt) {
        try { visionSupported.value = await _engine!.supportsVision; } catch (_) {}
      } else {
        final modelDir = file.parent;
        final files = await modelDir.list().whereType<File>().toList();
        final modelStem = p.basenameWithoutExtension(filename).toLowerCase();
        final projector = files.where((candidate) {
          final n = p.basename(candidate.path).toLowerCase();
          if (!n.contains('mmproj') || !n.endsWith('.gguf')) return false;
          // Prefer projectors that name this model family; allow a generic
          // mmproj only when there is exactly one projector in the directory.
          return n.contains('qwen3.5') || n.contains(modelStem);
        }).toList();
        final genericProjectors = files.where((candidate) {
          final n = p.basename(candidate.path).toLowerCase();
          return n.contains('mmproj') && n.endsWith('.gguf');
        }).toList();
        final candidates = projector.isNotEmpty
            ? projector
            : genericProjectors.length == 1 ? genericProjectors : <File>[];

        if (candidates.isNotEmpty) {
          try {
            loadingStatusMsg.value = 'Loading vision projector...';
            await _engine!.loadMultimodalProjector(candidates.first.path);
            visionSupported.value = await _engine!.supportsVision;
            log?.info(
              'Vision projector loaded: ${p.basename(candidates.first.path)}; supportsVision=${visionSupported.value}',
              source: 'LLM',
            );
          } catch (e) {
            visionSupported.value = false;
            log?.error('Vision projector unavailable: $e', source: 'LLM');
          }
        }
      }

      loadingProgress.value = 1.0;
      loadingStatusMsg.value = visionSupported.value ? 'Model ready · Vision ready!' : 'Model ready!';
      isLoaded.value = true;
      loadedModelPath.value = path;
      log?.info('Model loaded successfully: $filename', source: 'LLM');

      await wakelockService?.enableForInference(modelName: p.basenameWithoutExtension(path));
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      isLoaded.value = false;
      loadedModelPath.value = '';
      visionSupported.value = false;
      await _fullTeardown();
      log?.error('Model load failed: $e', source: 'LLM');

      final errStr = e.toString().toLowerCase();
      if (errStr.contains('timeout') || errStr.contains('timed out')) {
        throw Exception('Model loading timed out. Try a smaller model or check the file integrity.');
      }
      if (errStr.contains('memory') || errStr.contains('alloc') || errStr.contains('oom')) {
        throw Exception('Not enough RAM to load this model. Try a smaller model.');
      }
      if (errStr.contains('permission') || errStr.contains('access') || errStr.contains('selinux')) {
        throw Exception('File access denied. Move the model into the app models directory and try again.');
      }
      if (errStr.contains('invalid') || errStr.contains('corrupt') || errStr.contains('magic')) {
        throw Exception('Invalid or corrupted model file: "$filename".');
      }
      if (Platform.isAndroid && (errStr.contains('signal 11') || errStr.contains('segfault'))) {
        throw Exception('Model loading crashed. This may be insufficient memory or an incompatible model format.');
      }
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

  static final _stopPatterns = RegExp(
    r'<\|end\|>|<\|eot_id\|>|<\|endoftext\|>|<\|im_end\|>|<\|im_start\|>'
    r'|<end_of_turn>|<start_of_turn>|<\|assistant\|>|<\|user\|>|<\|system\|>|<\|pad\|>'
    r'|</s>|<s>|\[INST\]|\[/INST\]|\[end\]',
  );

  static final _userTurnPattern = RegExp(
    r'<\|user\|>|<\|im_start\|>\s*user|<start_of_turn>\s*user|\[INST\]',
  );

  Stream<String> generate({
    required List<Map<String, String>> messages,
    String? systemPrompt,
    double temperature = 0.7,
  }) async* {
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
        if (stopwatch.elapsedMilliseconds > 0) {
          tokensPerSecond.value = tokenCount / (stopwatch.elapsedMilliseconds / 1000);
        }
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
          final safe = buffer.substring(0, buffer.length - 30);
          buffer = buffer.substring(buffer.length - 30);
          yield safe;
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

  Stream<String> generateChatCompletion({
    required List<LlamaChatMessage> messages,
    GenerationParams params = const GenerationParams(),
  }) async* {
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
        if (stopwatch.elapsedMilliseconds > 0) {
          tokensPerSecond.value = tokenCount / (stopwatch.elapsedMilliseconds / 1000);
        }
        yield content;
      }
    } finally {
      stopwatch.stop();
      lastGenerationTokens.value = tokenCount;
      lastGenerationSpeed.value = tokensPerSecond.value;
      isGenerating.value = false;
    }
  }

  /// Vision/media-capable chat path. The native runtime handles the image
  /// path; this is used only after a runtime capability check succeeds.
  Stream<String> generateMultimodalCompletion({
    required List<LlamaChatMessage> messages,
    required String imagePath,
    String prompt = 'Describe this image.',
    GenerationParams params = const GenerationParams(),
  }) async* {
    if (_engine == null || !isLoaded.value) throw StateError('No model loaded.');
    if (!visionSupported.value) {
      throw StateError('Vision is not available for the loaded model. Add a matching mmproj file for GGUF vision models.');
    }
    if (isGenerating.value) throw StateError('Another generation is already in progress.');

    final multimodalMessages = <LlamaChatMessage>[...messages];
    multimodalMessages.add(
      LlamaChatMessage.withContent(
        role: LlamaChatRole.user,
        content: [
          LlamaImageContent(path: imagePath),
          LlamaTextContent(prompt),
        ],
      ),
    );

    yield* generateChatCompletion(messages: multimodalMessages, params: params);
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
    try {
      final wakelockService = Get.find<WakelockService>();
      await wakelockService.disable();
    } catch (_) {}
  }

  String _buildPrompt(List<Map<String, String>> messages, String? systemPrompt) {
    final buffer = StringBuffer();
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      buffer.writeln('<|system|>');
      buffer.writeln(systemPrompt);
      buffer.writeln('<|end|>');
    }
    for (final msg in messages) {
      final role = msg['role'] ?? 'user';
      final content = msg['content'] ?? '';
      buffer.writeln('<|$role|>');
      buffer.writeln(content);
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
