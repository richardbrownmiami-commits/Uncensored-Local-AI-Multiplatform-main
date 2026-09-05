import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../controllers/model_controller.dart';
import '../models/ai_model_info.dart';
import '../services/model_manager.dart';

/// Featured test target for models that combine chat, tool calling and vision.
/// The capability labels describe the model target; runtime availability is
/// intentionally kept separate because the current GGUF loader still needs
/// multimodal projector/input wiring before vision can be claimed as working.
class MultimodalTestCard extends StatelessWidget {
  final AiModelInfo model;
  final ModelController controller;
  final ModelManager manager;

  const MultimodalTestCard({
    super.key,
    required this.model,
    required this.controller,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    final downloaded = manager.isModelDownloaded(model);
    final loaded = controller.selectedModelFilename.value == model.filename &&
        controller.isModelLoaded;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.bgPanel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withOpacity(0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: AppColors.accentHi,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Multimodal Test Target',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accentHi,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      model.name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: context.text,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Large-model compatibility target for chat + tool calling + vision/image input.',
            style: TextStyle(fontSize: 12, color: context.textM, height: 1.35),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: model.capabilities.map(_capabilityChip).toList(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              _meta(context, Icons.storage_rounded, '${model.sizeGb} GB'),
              _meta(context, Icons.memory_rounded, 'Min ${model.minRamGb} GB RAM'),
              _meta(context, Icons.science_outlined, 'Runtime test'),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Test order: GGUF load → chat → tool-call parser → image/vision input. '
              'Vision is not marked working until the native projector/input path is implemented and tested.',
              style: TextStyle(fontSize: 11, color: context.textD, height: 1.35),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: loaded
                  ? null
                  : downloaded
                      ? () => controller.loadModel(model.filename)
                      : () => controller.downloadModel(model),
              icon: Icon(downloaded ? Icons.play_arrow_rounded : Icons.download_rounded),
              label: Text(
                loaded
                    ? 'Loaded — Ready for Runtime Tests'
                    : downloaded
                        ? 'Load Test Model'
                        : 'Download Test Model (${model.sizeGb} GB)',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.green.withOpacity(0.25),
                disabledForegroundColor: AppColors.green,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _capabilityChip(String capability) {
    final labels = <String, String>{
      'chat': 'CHAT',
      'tools': 'TOOLS',
      'vision': 'VISION',
      'image-input': 'IMAGE INPUT',
      'image-generation': 'IMAGE GENERATION',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppColors.accent.withOpacity(0.25)),
      ),
      child: Text(
        labels[capability] ?? capability.toUpperCase(),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.accentHi,
        ),
      ),
    );
  }

  Widget _meta(BuildContext context, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: context.textD),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 11, color: context.textM)),
      ],
    );
  }
}
