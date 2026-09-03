import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import '../services/tool_parser.dart';

/// Shows the pending GitHub write request and lets the user approve or
/// cancel it. This is the only UI path that leads to GitHubService.commitFile().
/// Call [maybeShow] from the chat screen's build method, wrapped in Obx,
/// watching ChatController.pendingAction.
class GithubActionConfirmDialog extends StatelessWidget {
  final ToolRequest action;
  const GithubActionConfirmDialog({super.key, required this.action});

  static Future<void> maybeShow(BuildContext context, ToolRequest action) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => GithubActionConfirmDialog(action: action),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = Get.find<ChatController>();
    final content = action.content ?? '';
    final preview =
        content.length > 2000 ? '${content.substring(0, 2000)}\n…(truncated)' : content;

    return AlertDialog(
      title: const Text('AI wants to update GitHub'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('File: ${action.path}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('Commit message: ${action.message ?? ''}'),
              const SizedBox(height: 12),
              const Text('New content:',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(preview,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
              const SizedBox(height: 8),
              const Text(
                'Review this before approving — a small local model can make mistakes.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            chat.rejectPendingAction();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(context).pop();
            final error = await chat.approvePendingAction();
            if (error != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('GitHub push failed: $error')),
              );
            } else if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Pushed to GitHub.')),
              );
            }
          },
          child: const Text('Approve & Push'),
        ),
      ],
    );
  }
}
