import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/prompt_context_service.dart';

class AiCoreFilesScreen extends StatefulWidget {
  const AiCoreFilesScreen({super.key});

  @override
  State<AiCoreFilesScreen> createState() => _AiCoreFilesScreenState();
}

class _AiCoreFilesScreenState extends State<AiCoreFilesScreen> {
  final _service = Get.find<PromptContextService>();
  final _files = PromptContextService.coreFileNames;
  late String _selected;
  late TextEditingController _editor;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected = _files.first;
    _editor = TextEditingController(text: _service.currentCoreFile(_selected));
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  void _select(String name) {
    setState(() {
      _selected = name;
      _editor.text = _service.currentCoreFile(name);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _service.saveCoreFile(_selected, _editor.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI core file saved. It will be injected into new model generations.')),
        );
        setState(() {});
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    await _service.resetCoreFile(_selected);
    setState(() => _editor.text = _service.currentCoreFile(_selected));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Core Files'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _reset,
            icon: const Icon(Icons.restore),
            label: const Text('Reset'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 190,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final name = _files[index];
                final selected = name == _selected;
                final overridden = _service.hasOverride(name);
                return ListTile(
                  selected: selected,
                  leading: Icon(name.endsWith('.json') ? Icons.data_object : Icons.description_outlined),
                  title: Text(name, style: const TextStyle(fontSize: 13)),
                  trailing: overridden
                      ? const Icon(Icons.edit_note, size: 18)
                      : const Icon(Icons.inventory_2_outlined, size: 16),
                  onTap: () => _select(name),
                );
              },
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _selected,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _service.hasOverride(_selected)
                        ? 'Editable on-device override — used instead of the bundled file.'
                        : 'Bundled default — edit and Save to create an on-device override.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: TextField(
                      controller: _editor,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                        hintText: 'Edit this AI core file…',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: Icon(_saving ? Icons.hourglass_top : Icons.save_outlined),
                    label: Text(_saving ? 'Saving…' : 'Save AI Core File'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
