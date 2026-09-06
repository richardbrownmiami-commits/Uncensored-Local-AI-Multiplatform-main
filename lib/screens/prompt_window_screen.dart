import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/skill_service.dart';
import '../services/llm_service.dart';
import '../services/tool_parser.dart';

class PromptWindowScreen extends StatefulWidget {
  const PromptWindowScreen({super.key});

  @override
  State<PromptWindowScreen> createState() => _PromptWindowScreenState();
}

class _PromptWindowScreenState extends State<PromptWindowScreen> {
  final _prompt = TextEditingController();
  final _system = TextEditingController();
  final _context = TextEditingController();
  final _output = TextEditingController();
  final _skillService = Get.find<SkillService>();
  bool _running = false;
  double _temperature = 0.7;
  ToolKind? _tool;

  @override
  void dispose() {
    _prompt.dispose();
    _system.dispose();
    _context.dispose();
    _output.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_prompt.text.trim().isEmpty) return;
    setState(() {
      _running = true;
      _output.clear();
    });
    try {
      final result = await _skillService.runPrompt(
        prompt: _prompt.text,
        customSystemPrompt: _system.text,
        injectedContext: _context.text,
        temperature: _temperature,
      );
      if (mounted) _output.text = result;
    } catch (e) {
      if (mounted) {
        _output.text = 'Error: $e';
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _injectToolResult() async {
    final kind = _tool;
    if (kind == null) return;
    try {
      final result = await _skillService.runToolAndInject(ToolRequest(kind: kind));
      if (result.isNotEmpty) {
        final current = _context.text.trim();
        _context.text = current.isEmpty ? result : '$current\n\n$result';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final llm = Get.find<LlmService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt Window'),
        actions: [
          Obx(() => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: Text(llm.isLoaded.value
                      ? llm.loadedModelFilename
                      : 'No model loaded'),
                ),
              )),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Obx(() => DropdownButtonFormField<String>(
                      value: _skillService.selectedSkillId.value,
                      decoration: const InputDecoration(labelText: 'Skill'),
                      items: _skillService.skills
                          .map((skill) => DropdownMenuItem(
                                value: skill.id,
                                child: Text(skill.name),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) _skillService.selectSkill(value);
                      },
                    )),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _system,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'System instructions',
                hintText: 'Instructions injected before the user prompt',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _context,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Direct context injection',
                hintText: 'Paste text, code, notes, documents, or tool results here',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<ToolKind>(
                    value: _tool,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Inject tool result',
                    ),
                    items: const [
                      DropdownMenuItem(value: ToolKind.dateTime, child: Text('Date / time')),
                      DropdownMenuItem(value: ToolKind.systemInfo, child: Text('System info')),
                    ],
                    onChanged: (value) => setState(() => _tool = value),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _tool == null ? null : _injectToolResult,
                  icon: const Icon(Icons.add),
                  label: const Text('Inject'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Temperature: ${_temperature.toStringAsFixed(2)}'),
            Slider(
              value: _temperature,
              min: 0,
              max: 2,
              divisions: 40,
              onChanged: (value) => setState(() => _temperature = value),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _prompt,
              maxLines: 8,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Prompt',
                hintText: 'This is sent directly to the currently loaded GGUF model',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: Icon(_running ? Icons.hourglass_top : Icons.play_arrow),
              label: Text(_running ? 'Running…' : 'Run on loaded model'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _output,
              readOnly: true,
              maxLines: 14,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Model output',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
