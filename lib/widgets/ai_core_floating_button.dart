import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Always-visible entry point for the model configuration/prompt workspace.
/// The previous implementation registered the screens as routes but did not
/// expose them from the main Android chat UI, making the fields effectively
/// undiscoverable.
class AiCoreFloatingButton extends StatelessWidget {
  const AiCoreFloatingButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: 82,
      child: SafeArea(
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(28),
          child: PopupMenuButton<String>(
            tooltip: 'AI controls',
            onSelected: (value) {
              if (value == 'core') Get.toNamed('/ai-core-files');
              if (value == 'prompt') Get.toNamed('/prompt-window');
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'core',
                child: ListTile(
                  leading: Icon(Icons.folder_special_outlined),
                  title: Text('AI Core Files'),
                  subtitle: Text('Soul, identity, skills, tools, memory, prompt'),
                ),
              ),
              PopupMenuItem(
                value: 'prompt',
                child: ListTile(
                  leading: Icon(Icons.tune_rounded),
                  title: Text('Prompt Workspace'),
                  subtitle: Text('Skill, system prompt, context and model output'),
                ),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 19),
                  SizedBox(width: 8),
                  Text('AI Controls'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
