import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:device_info_plus/device_info_plus.dart';

import 'wakelock_service.dart';
import 'chat_storage_service.dart';
import 'log_service.dart';

/// Wraps llamadart's LlamaEngine for model loading, generation, and lifecycle.
class LlmService extends GetxService {
  LlamaEngine? _engine;
  LlamaBackend? _backend;

  final isLoaded = false.obs;
  final isGenerating = false.obs;
  final loadedModelPath = ''.obs;
  final tokensPerSecond = 0.0.obs;
  final lastGenerationTokens = 0.obs;
  final lastGenerationSpeed = 0.0.obs;

  // ── Loading progress tracking ──────────────────────────────
  final isLoadingModel = false.obs;
  final loadingProgress = 0.0.obs; // 0.0 to 1.0
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

  /// Initialize the service.
  Future<LlmService> init() async {
    // Backend is created fresh per loadModel() call — no init needed here
    return this;
  }

  /// Cancel an in-progress model load.
  void cancelLoading() {
    _loadingCancelled = true;
  }

  /// Load a GGUF model from [path] with progress tracking.
  Future<void> loadModel(String path) async {
    LogService? log;
    try { log = Get.find<LogService>(); } catch (_) {}

    // Verify file exists first
    final file = File(path);
    if (!await file.exists()) {
      log?.error('Model file not found: $path', source: 'LLM');
      throw Exception('Model file not found: $path');
    }

    final filename = p.basename(path);
    log?.info('Loading model: $filename', source: 'LLM');

    // GGUF Magic Bytes Validation
    // Check first 8 bytes for "GGUF" signature (GGUF format identifier)
    loadingStatusMsg.value = 'Validating GGUF file...';
    loadingProgress.value = 0.0;
    try {
      final randomAccess = await file.open(mode: FileMode.read);
      final magicBytes = await randomAccess.read(8);
      await randomAccess.close();
      
      if (magicBytes.length < 4 || String.fromCharCodes(magicBytes.sublist(0, 4)) != 'GGUF') {
        log?.error('Invalid GGUF file: magic bytes mismatch', source: 'LLM');
        throw Exception(
          'Invalid GGUF file: "$filename". '
          'File does not have valid GGUF format signature.',
        );
      }
      log?.info('GGUF magic bytes validated', source: 'LLM');
    } catch (e) {
      log?.error('GGUF validation failed: $e', source: 'LLM');
      throw Exception(
        'Failed to validate GGUF file: "$filename". '
        'Error: $e',
      );
    }

    _loadingCancelled = false;
    isLoadingModel.value = true;
    loadingProgress.value = 0.05;
    loadingStatusMsg.value = 'Preparing...';

    // Enable wake lock during model loading (heavy memory operation)
    WakelockService? wakelockService;
    try {
      wakelockService = Get.find<WakelockService>();
    } catch (_) {}

    // Unload previous if any — MUST fully tear down engine + backend
    if (_engine != null || isLoaded.value) {
      loadingStatusMsg.value = 'Unloading previous model...';
      loadingProgress.value = 0.05;
      await _fullTeardown();
      // Give native side time to release resources
      await Future.delayed(const Duration(milliseconds: 500));
      if (_loadingCancelled) {
        _resetLoadingState();
        return;
      }
    }

    // Fresh backend + engine for every load — prevents stale native state
    // Wrapped in try-catch to handle SELinux crashes on Android where
    // ggml_backend_load_all() attempts to scan '/' which is denied.
    try {
      _backend = LlamaBackend();
      _engine = LlamaEngine(_backend!);
    } catch (e) {
      _backend = null;
      _engine = null;
      _resetLoadingState();
      log?.error('Engine init failed: $e', source: 'LLM');
      throw Exception(
        'Failed to initialize AI engine. '
        'This may be a device compatibility issue. '
        'Error: $e',
      );
    }

    try {
      loadingStatusMsg.value = 'Loading into memory...';
      loadingProgress.value = 0.1;

      // Get file size for display
      final fileSize = await file.length();
      final sizeGb = (fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2);
      loadingStatusMsg.value = 'Loading $sizeGb GB model...';
      loadingProgress.value = 0.0;

      // Use smaller context on Android to prevent OOM kills.
      // Desktop can handle 2048, but Android devices with limited RAM
      // need 1024 to avoid the Low Memory Killer (LMK).
      final contextSize = Platform.isAndroid ? 1024 : 2048;

      // Map the string backend to GpuBackend enum
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

      // Read gpu layers
      final userGpuLayers = storage.gpuLayers;

      // Optimize threads: 4 for both generation and batch processing to keep memory stable.
      final params = ModelParams(
        contextSize: contextSize,
        gpuLayers: userGpuLayers, 
        preferredBackend: parsedBackend,
        numberOfThreads: Platform.numberOfProcessors > 4 ? 4 : 0, 
        numberOfThreadsBatch: Platform.numberOfProcessors > 4 ? 4 : 0,
      );

      log?.info('Backend=$parsedBackend, GPU layers=$userGpuLayers, ctx=$contextSize, threads=${Platform.numberOfProcessors > 4 ? 4 : 0}', source: 'LLM');

      // RAM Validation - Check if device has enough memory
      // GGUF models need ~1.5x their file size in RAM
      if (Platform.isAndroid || Platform.isIOS) {
        loadingStatusMsg.value = 'Checking available RAM...';
        loadingProgress.value = 0.15;
        
        try {
          // Get total RAM on mobile devices
          final deviceInfo = await DeviceInfoPlugin().deviceInfo;
          double totalRamGb = 0;
          if (deviceInfo is AndroidDeviceInfo) {
            // AndroidDeviceInfo uses memTotalKb (kilobytes) not memTotalPhysicalBytes
            totalRamGb = (deviceInfo.memTotalKb ?? 0) / (1024 * 1024);
          } else if (deviceInfo is IosDeviceInfo) {
            // IosDeviceInfo doesn't have physicalMemory, use a reasonable default for iOS
            // Most iOS devices have 4-8GB RAM
            totalRamGb = 4.0; // Conservative default
          }
          
          final fileSizeGb = fileSize / (1024 * 1024 * 1024);
          final requiredRamGb = fileSizeGb * 1.5; // 1.5x multiplier for safety
          
          if (totalRamGb > 0 && requiredRamGb > totalRamGb * 0.7) {
            // Use 70% of total RAM as threshold (leave room for OS)
            log?.error('Insufficient RAM: need ${requiredRamGb.toStringAsFixed(1)}GB, have ${totalRamGb.toStringAsFixed(1)}GB', source: 'LLM');
            throw Exception(
              'Not enough RAM to load this model. '
              'Model requires ~${requiredRamGb.toStringAsFixed(1)}GB, '
              'device has ${totalRamGb.toStringAsFixed(1)}GB. '
              'Try a smaller model.',
            );
          }
          log?.info('RAM check passed: ${totalRamGb.toStringAsFixed(1)}GB available, ${requiredRamGb.toStringAsFixed(1)}GB required', source: 'LLM');
        } catch (e) {
          log?.warn('Could not determine device RAM: $e', source: 'LLM');
          // Continue without RAM check if we can't get device info
        }
      }

      // Show loading progress - llamadart doesn't provide native progress callbacks
      // so we use a simple animated progress that properly reaches completion
      Timer? progressTimer;
      progressTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
        if (_loadingCancelled) {
          timer.cancel();
          return;
        }
        final current = loadingProgress.value;
        if (current < 0.99) {
          loadingProgress.value = current + 0.01;
          loadingStatusMsg.value = 'Loading ${((current + 0.01) * 100).toStringAsFixed(0)}%...';
        }
      });

      // Load with timeout - 10 minutes maximum
      loadingStatusMsg.value = 'Loading model into memory...';
      loadingProgress.value = 0.2;
      
      try {
        await _engine!.loadModel(path, modelParams: params).timeout(
          const Duration(minutes: 10),
          onTimeout: () {
            throw TimeoutException(
              'Model loading timed out after 10 minutes. '
              'This model may be too large for your device or corrupted.',
            );
          },
        );
      } on TimeoutException catch (e) {
        progressTimer.cancel();
        throw Exception(e.message);
      }
      progressTimer.cancel();

      if (_loadingCancelled) {
        await _fullTeardown();
        _resetLoadingState();
        return;
      }

      loadingProgress.value = 1.0;
      loadingStatusMsg.value = 'Model ready!';
      isLoaded.value = true;
      loadedModelPath.value = path;
      log?.info('Model loaded successfully: $filename', source: 'LLM');

      // Enable wake lock for inference on mobile (keeps app from being killed)
      final modelName = p.basenameWithoutExtension(path);
      await wakelockService?.enableForInference(modelName: modelName);

      // Brief delay to show 100%
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      isLoaded.value = false;
      loadedModelPath.value = '';
      await _fullTeardown();
      log?.error('Model load failed: $e', source: 'LLM');

      final errStr = e.toString().toLowerCase();
      
      // Provide specific error messages for different failure types
      if (errStr.contains('timeout') || errStr.contains('timed out')) {
        throw Exception(
          'Model loading timed out. '
          'The model may be too large for your device, corrupted, or the file may be inaccessible. '
          'Try a smaller model or check the file integrity.',
        );
      }
      
      if (errStr.contains('memory') || errStr.contains('alloc') || errStr.contains('oom')) {
        throw Exception(
          'Not enough RAM to load this model. '
          'This model requires more memory than your device has available. '
          'Try a smaller model (e.g., Gemma 2 2B at ~1.6GB, Phi-3.5-mini at ~2.5GB).',
        );
      }
      
      if (errStr.contains('permission') || errStr.contains('access') || errStr.contains('selinux')) {
        throw Exception(
          'File access denied. '
          'The app cannot access the model file. '
          'On Android, try moving the file to the app\'s models directory or check file permissions.',
        );
      }
      
      if (errStr.contains('invalid') || errStr.contains('corrupt') || errStr.contains('magic')) {
        throw Exception(
          'Invalid or corrupted GGUF file. '
          'The file "$filename" does not appear to be a valid GGUF model. '
          'Try downloading the model again from a trusted source.',
        );
      }
      
      if (Platform.isAndroid && errStr.contains('signal 11') || errStr.contains('segfault')) {
        throw Exception(
          'Model loading crashed. '
          'This may be due to insufficient memory or an incompatible model format. '
          'Try a smaller model or restart the app.',
        );
      }
      
      // Generic fallback
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

  /// Tokens/patterns the model may emit that should be stripped from output.
  /// Covers ChatML, Llama, Gemma, Phi, Mistral, and other common formats.
  static final _stopPatterns = RegExp(
    r'<\|end\|>'
    r'|<\|eot_id\|>'
    r'|<\|endoftext\|>'
    r'|<\|im_end\|>'
    r'|<\|im_start\|>'
    r'|<end_of_turn>'
    r'|<start_of_turn>'
    r'|<\|assistant\|>'
    r'|<\|user\|>'
    r'|<\|system\|>'
    r'|<\|pad\|>'
    r'|</s>'
    r'|<s>'
    r'|\[INST\]'
    r'|\[/INST\]'
    r'|\[end\]',
  );

  /// Pattern that signals the model is hallucinating a new user turn — stop immediately.
  static final _userTurnPattern = RegExp(
    r'<\|user\|>|<\|im_start\|>\s*user|<start_of_turn>\s*user|\[INST\]',
  );

  /// Generate a streaming response.
  /// [messages] is a list of {role, content} maps.
  /// [systemPrompt] is prepended as a system message.
  /// Returns a Stream of String tokens.
  Stream<String> generate({
    required List<Map<String, String>> messages,
    String? systemPrompt,
    double temperature = 0.7,
  }) async* {
    if (_engine == null || !isLoaded.value) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    if (isGenerating.value) {
      throw StateError('Another generation is already in progress.');
    }

    isGenerating.value = true;
    tokensPerSecond.value = 0.0;
    final stopwatch = Stopwatch()..start();
    int tokenCount = 0;

    // Buffer to detect multi-token stop sequences
    String buffer = '';

    try {
      // Build the full prompt from messages
      final prompt = _buildPrompt(messages, systemPrompt);

      await for (final token in _engine!.generate(prompt)) {
        tokenCount++;
        if (stopwatch.elapsedMilliseconds > 0) {
          tokensPerSecond.value =
              tokenCount / (stopwatch.elapsedMilliseconds / 1000);
        }

        // Accumulate into buffer for stop-pattern detection
        buffer += token;

        // Check if model is hallucinating a user turn — stop immediately
        if (_userTurnPattern.hasMatch(buffer)) {
          final cleaned = buffer
              .replaceAll(_stopPatterns, '')
              .replaceAll(_userTurnPattern, '')
              .trim();
          if (cleaned.isNotEmpty) {
            yield cleaned;
          }
          break;
        }

        // Check if buffer contains any stop pattern
        if (_stopPatterns.hasMatch(buffer)) {
          // Yield everything before the stop pattern, then stop
          final cleaned = buffer.replaceAll(_stopPatterns, '').trim();
          if (cleaned.isNotEmpty) {
            yield cleaned;
          }
          break;
        }

        // If buffer is getting long enough that we know it's safe, flush it
        // Keep last 30 chars to detect split stop sequences
        if (buffer.length > 40) {
          final safe = buffer.substring(0, buffer.length - 30);
          buffer = buffer.substring(buffer.length - 30);
          yield safe;
        }
      }

      // Flush any remaining buffer (cleaning all control patterns)
      if (buffer.isNotEmpty) {
        final cleaned = buffer
            .replaceAll(_stopPatterns, '')
            .replaceAll(_userTurnPattern, '')
            .trim();
        if (cleaned.isNotEmpty) {
          yield cleaned;
        }
      }
    } finally {
      stopwatch.stop();
      lastGenerationTokens.value = tokenCount;
      lastGenerationSpeed.value = tokensPerSecond.value;
      isGenerating.value = false;
    }
  }

  /// Generate a chat completion using llamadart's chat-template API.
  Stream<String> generateChatCompletion({
    required List<LlamaChatMessage> messages,
    GenerationParams params = const GenerationParams(),
  }) async* {
    if (_engine == null || !isLoaded.value) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    if (isGenerating.value) {
      throw StateError('Another generation is already in progress.');
    }

    isGenerating.value = true;
    tokensPerSecond.value = 0.0;
    final stopwatch = Stopwatch()..start();
    int tokenCount = 0;

    try {
      await for (final chunk in _engine!.create(
        messages,
        params: params,
        toolChoice: ToolChoice.none,
      )) {
        final choice = chunk.choices.isNotEmpty ? chunk.choices.first : null;
        final content = choice?.delta.content;
        if (content == null || content.isEmpty) continue;

        tokenCount++;
        if (stopwatch.elapsedMilliseconds > 0) {
          tokensPerSecond.value =
              tokenCount / (stopwatch.elapsedMilliseconds / 1000);
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

  Future<int> countTokens(String text) async {
    if (_engine == null || !isLoaded.value) return 0;
    try {
      return await _engine!.getTokenCount(text);
    } catch (_) {
      return 0;
    }
  }

  /// Stop ongoing generation.
  Future<void> stopGeneration() async {
    _generateSub?.cancel();
    _generateSub = null;
    _engine?.cancelGeneration();
    isGenerating.value = false;
  }

  /// Full native teardown — dispose engine AND backend to prevent stale state.
  Future<void> _fullTeardown() async {
    if (_engine != null) {
      try {
        await _engine!.dispose();
      } catch (_) {
        // Engine may already be in broken state — ignore
      }
      _engine = null;
    }
    // Also destroy the backend — it can't be reused after engine disposal
    _backend = null;
    isLoaded.value = false;
    loadedModelPath.value = '';
    tokensPerSecond.value = 0.0;
  }

  /// Unload the current model and free memory.
  Future<void> unloadModel() async {
    await _fullTeardown();

    // Disable wake lock when model is unloaded
    try {
      final wakelockService = Get.find<WakelockService>();
      await wakelockService.disable();
    } catch (_) {}
  }

  /// Build a single prompt string from chat messages.
  String _buildPrompt(
    List<Map<String, String>> messages,
    String? systemPrompt,
  ) {
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
