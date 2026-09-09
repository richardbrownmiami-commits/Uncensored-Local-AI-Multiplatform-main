import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../services/chat_storage_service.dart';
import '../services/llm_service.dart';
import '../theme/app_colors.dart';

/// SmolChat-inspired control center for local GGUF chat.
///
/// This is deliberately UI-only: it uses the existing model/controller and
/// runtime configuration services rather than introducing another inference
/// engine or changing the native llama.cpp path.
class SmolChatControlScreen extends StatefulWidget {
  const SmolChatControlScreen({super.key});

  @override
  State<SmolChatControlScreen> createState() => _SmolChatControlScreenState();
}

class _SmolChatControlScreenState extends State<SmolChatControlScreen> {
  final _models = Get.find<ModelController>();
  final _storage = Get.find<ChatStorageService>();
  final _llm = Get.find<LlmService>();
  late double _temperature;
  late int _context;
  late int _threads;
  late int _batch;

  @override
  void initState() {
    super.initState();
    _temperature = _storage.defaultTemperature;
    _context = _storage.contextSize;
    _threads = _storage.cpuThreads;
    _batch = _storage.batchSize;
  }

  void _saveRuntime() {
    _storage.defaultTemperature = _temperature;
    _storage.contextSize = _context;
    _storage.cpuThreads = _threads;
    _storage.batchSize = _batch;
    Get.snackbar(
      'Runtime settings saved',
      'Settings will be used on the next model load.',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        backgroundColor: context.bg,
        elevation: 0,
        titleSpacing: 20,
        title: const Text('Local AI'),
        actions: [
          Obx(() => Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Chip(
                  avatar: Icon(
                    _llm.isLoaded.value ? Icons.circle : Icons.circle_outlined,
                    size: 10,
                    color: _llm.isLoaded.value ? Colors.green : context.textD,
                  ),
                  label: Text(_llm.isLoaded.value ? 'Ready' : 'No model'),
                ),
              )),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _hero(context),
            const SizedBox(height: 16),
            _sectionTitle(context, 'MODEL'),
            _modelPanel(context),
            const SizedBox(height: 16),
            _sectionTitle(context, 'RUNTIME'),
            _runtimePanel(context),
            const SizedBox(height: 16),
            _sectionTitle(context, 'QUICK ACTIONS'),
            _quickActions(context),
          ],
        ),
      ),
    );
  }

  Widget _hero(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.accentGradient,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .16),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SmolChat mode', style: TextStyle(color: Colors.white70, fontSize: 12)),
                SizedBox(height: 3),
                Text('Private local inference', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                SizedBox(height: 4),
                Text('GGUF • llama.cpp • CPU', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: context.textD)),
    );
  }

  Widget _modelPanel(BuildContext context) {
    return Obx(() {
      final selected = _models.selectedModelFilename.value;
      final info = selected == null ? null : _models.getModelInfo(selected);
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: context.bgPanel, borderRadius: BorderRadius.circular(18), border: Border.all(color: context.border)),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.memory_rounded, color: AppColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(info?.name ?? selected ?? 'No GGUF selected', style: TextStyle(fontWeight: FontWeight.w700, color: context.text), maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Text(info == null ? 'Import a GGUF model to begin' : '${info.sizeGb.toStringAsFixed(2)} GB • ${_llm.isLoaded.value ? 'loaded' : 'available'}', style: TextStyle(fontSize: 12, color: context.textM)),
                  ]),
                ),
                if (_llm.isLoaded.value)
                  IconButton(onPressed: _models.unloadCurrentModel, icon: const Icon(Icons.power_settings_new_rounded), tooltip: 'Unload'),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: OutlinedButton.icon(onPressed: _models.importModelFromFile, icon: const Icon(Icons.file_upload_outlined), label: const Text('Import GGUF'))),
                const SizedBox(width: 10),
                Expanded(child: FilledButton.icon(onPressed: selected == null ? null : () => _models.loadModel(selected), icon: const Icon(Icons.play_arrow_rounded), label: const Text('Load'))),
              ],
            ),
            if (_models.isLoadingModel.value) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _models.loadingProgress.value > 0 ? _models.loadingProgress.value : null),
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerLeft, child: Text(_models.loadingStatusMsg.value.isEmpty ? 'Loading model…' : _models.loadingStatusMsg.value, style: TextStyle(fontSize: 11, color: context.textM))),
            ],
          ],
        ),
      );
    });
  }

  Widget _runtimePanel(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: context.bgPanel, borderRadius: BorderRadius.circular(18), border: Border.all(color: context.border)),
      child: Column(
        children: [
          _sliderRow(context, 'Temperature', _temperature, 0.0, 2.0, (v) => setState(() => _temperature = v)),
          const Divider(height: 22),
          _choiceRow(context, 'Context', _context.toString(), [512, 1024, 2048, 4096, 8192], (v) => setState(() => _context = v)),
          _choiceRow(context, 'CPU threads', _threads.toString(), List.generate(8, (i) => i + 1), (v) => setState(() => _threads = v)),
          _choiceRow(context, 'Batch', _batch.toString(), [32, 64, 128, 256, 512, 1024], (v) => setState(() => _batch = v)),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _saveRuntime, icon: const Icon(Icons.save_outlined), label: const Text('Save runtime settings'))),
        ],
      ),
    );
  }

  Widget _sliderRow(BuildContext context, String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Text(label, style: TextStyle(color: context.text, fontWeight: FontWeight.w600)), const Spacer(), Text(value.toStringAsFixed(2), style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700))]),
      Slider(value: value, min: min, max: max, divisions: 40, onChanged: onChanged),
    ]);
  }

  Widget _choiceRow(BuildContext context, String label, String current, List<int> choices, ValueChanged<int> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(color: context.text, fontWeight: FontWeight.w600))),
        DropdownButton<int>(value: choices.contains(int.tryParse(current)) ? int.parse(current) : choices.first, items: choices.map((v) => DropdownMenuItem(value: v, child: Text('$v'))).toList(), onChanged: (v) { if (v != null) onChanged(v); }),
      ]),
    );
  }

  Widget _quickActions(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        ActionChip(avatar: const Icon(Icons.tune_rounded, size: 18), label: const Text('Prompt workspace'), onPressed: () => Get.toNamed('/prompt-window')),
        ActionChip(avatar: const Icon(Icons.folder_special_outlined, size: 18), label: const Text('AI core files'), onPressed: () => Get.toNamed('/ai-core-files')),
        ActionChip(avatar: const Icon(Icons.history_rounded, size: 18), label: const Text('Chat history'), onPressed: () => Get.back()),
      ],
    );
  }
}
