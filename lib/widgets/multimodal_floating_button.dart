import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../theme/app_colors.dart';

/// Placeholder for image input. The current Android llama.cpp build supports
/// GGUF text inference; multimodal sending is intentionally disabled until
/// the ChatController and runtime expose a matching multimodal API.
class MultimodalFloatingButton extends StatelessWidget {
  const MultimodalFloatingButton({super.key});

  @override
  Widget build(BuildContext context) {
    final model = Get.find<ModelController>();
    return Obx(() {
      if (!model.visionSupported || !model.isModelLoaded) {
        return const SizedBox.shrink();
      }
      return Positioned(
        right: 18,
        bottom: 82,
        child: Material(
          color: Colors.transparent,
          child: Tooltip(
            message: 'Image input is not enabled in this Android build yet',
            child: FloatingActionButton.small(
              heroTag: 'localVisionInput',
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              onPressed: () => Get.snackbar(
                'Image input unavailable',
                'This Android build currently supports GGUF text models only.',
                snackPosition: SnackPosition.BOTTOM,
              ),
              child: const Icon(Icons.image_outlined),
            ),
          ),
        ),
      );
    });
  }
}
