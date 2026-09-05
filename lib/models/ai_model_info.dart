/// Represents a downloadable/loadable AI model from the catalog.
class AiModelInfo {
  final String id;
  final String name;
  final String filename;
  final String url;
  final double sizeGb;
  final int minRamGb;
  final String label;        // UNCENSORED / STANDARD / CUSTOM
  final String badge;        // RECOMMENDED, HERETIC, etc.
  final String systemPrompt;
  final bool recommended;
  final List<String> capabilities; // chat, tools, vision, image-input, etc.

  const AiModelInfo({
    required this.id,
    required this.name,
    required this.filename,
    required this.url,
    required this.sizeGb,
    required this.minRamGb,
    required this.label,
    required this.badge,
    required this.systemPrompt,
    this.recommended = false,
    this.capabilities = const <String>[],
  });

  /// Builds accurate local metadata for the GGUF/LiteRT files the user
  /// already has on disk. This keeps imported/shared models useful even when
  /// they are not present in the remote download catalog.
  factory AiModelInfo.fromLocalFilename(String filename, {double sizeGb = 0}) {
    final lower = filename.toLowerCase();

    String name = filename;
    List<String> capabilities = const <String>['chat'];
    int minRamGb = 1;
    String badge = 'LOCAL';
    String systemPrompt = 'You are a helpful AI assistant.';

    if (lower == 'llama-3.2-1b-instruct-q5_k_m.gguf') {
      name = 'Llama 3.2 1B Instruct Q5_K_M';
      minRamGb = 2;
    } else if (lower == 'llama-3.2-1b-instruct-q4_k_s.gguf') {
      name = 'Llama 3.2 1B Instruct Q4_K_S';
      minRamGb = 2;
    } else if (lower == 'jarvis-0.5b.q8_0.gguf') {
      name = 'Jarvis 0.5B Q8_0';
      minRamGb = 2;
    } else if (lower == 'lfm2.5-350m.gguf') {
      name = 'LFM2.5 350M';
      minRamGb = 1;
      capabilities = const <String>['chat', 'tools', 'structured-json'];
      badge = 'LOCAL · TOOLS';
    } else if (lower == 'qwen3.5-0.8b-abliterated-huihui.gguf') {
      name = 'Qwen3.5 0.8B Abliterated';
      minRamGb = 2;
      capabilities = const <String>[
        'chat',
        'tools',
        'vision',
        'image-input',
        'video-input',
      ];
      badge = 'LOCAL · VISION · TOOLS';
    } else if (lower == 'osmosis-structure-0.6b-q4_k_m.gguf') {
      name = 'Osmosis-Structure 0.6B Q4_K_M';
      minRamGb = 1;
      capabilities = const <String>['chat', 'structured-json'];
      badge = 'LOCAL · JSON';
    } else if (lower == 'smollm2-360m-instruct-q8_0-3.gguf') {
      name = 'SmolLM2 360M Instruct Q8_0';
      minRamGb = 1;
    } else if (lower == 'qwen3_0_6b_mixed_int4.litertlm') {
      name = 'Qwen3 0.6B Mixed INT4 (LiteRT-LM)';
      minRamGb = 1;
      capabilities = const <String>['chat', 'litert-lm'];
      badge = 'LOCAL · LITERT-LM';
    } else if (lower == 'smollm2-135m-instruct.q8_0.gguf') {
      name = 'SmolLM2 135M Instruct Q8_0';
      minRamGb = 1;
    }

    return AiModelInfo(
      id: 'local_${filename.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}',
      name: name,
      filename: filename,
      url: 'local',
      sizeGb: sizeGb,
      minRamGb: minRamGb,
      label: 'CUSTOM',
      badge: badge,
      systemPrompt: systemPrompt,
      capabilities: capabilities,
    );
  }

  factory AiModelInfo.fromJson(Map<String, dynamic> json) {
    return AiModelInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      filename: json['filename'] as String,
      url: json['url'] as String,
      sizeGb: (json['sizeGb'] as num).toDouble(),
      minRamGb: (json['minRamGb'] as num).toInt(),
      label: json['label'] as String? ?? 'STANDARD',
      badge: json['badge'] as String? ?? '',
      systemPrompt: json['systemPrompt'] as String? ?? '',
      recommended: json['recommended'] as bool? ?? false,
      capabilities: (json['capabilities'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'filename': filename,
        'url': url,
        'sizeGb': sizeGb,
        'minRamGb': minRamGb,
        'label': label,
        'badge': badge,
        'systemPrompt': systemPrompt,
        'recommended': recommended,
        'capabilities': capabilities,
      };

  bool get isUncensored => label == 'UNCENSORED';
  bool get isStandard => label == 'STANDARD';
  bool get isCustom => label == 'CUSTOM';
  bool get supportsTools => capabilities.contains('tools');
  bool get supportsVision => capabilities.contains('vision');
  bool get supportsImageInput => capabilities.contains('image-input');
  bool get isLiteRtLm => capabilities.contains('litert-lm');
}
