import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import '../theme/app_colors.dart';

/// Global image-input action. It is only visible after the loaded runtime
/// reports real vision support, so a model card cannot falsely advertise an
/// image button when its GGUF projector is missing.
class MultimodalFloatingButton extends StatelessWidget {
  const MultimodalFloatingButton({super.key});

  Future<void> _pickImage(BuildContext context) async {
    final model = Get.find<ModelController>();
    if (!model.visionSupported) {
      Get.snackbar(
        'Vision unavailable',
        'Load a vision-capable model with its matching mmproj file first.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null || path.isEmpty) {
        Get.snackbar(
          'Image unavailable',
          'The selected image did not expose a local path on this platform.',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }

      final chat = Get.find<ChatController>();
      if (chat.activeChat == null) chat.newChat();
      await chat.sendMessage(
        '',
        modelFilename: model.selectedModelFilename.value,
        imagePath: path,
      );
    } catch (e) {
      Get.snackbar(
        'Image input failed',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

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
            message: 'Send image to local vision model',
            child: FloatingActionButton.small(
              heroTag: 'localVisionInput',
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              onPressed: () => _pickImage(context),
              child: const Icon(Icons.image_outlined),
            ),
          ),
        ),
      );
    });
  }
}
