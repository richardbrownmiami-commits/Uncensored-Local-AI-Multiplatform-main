import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../models/ai_model_info.dart';
import '../services/chat_storage_service.dart';
import '../services/model_manager.dart';

class ModelSettingsScreen extends StatefulWidget {
  final String modelFilename;

  const ModelSettingsScreen({Key? key, required this.modelFilename}) : super(key: key);

  @override
  _ModelSettingsScreenState createState() => _ModelSettingsScreenState();
}

class _ModelSettingsScreenState extends State<ModelSettingsScreen> {
  late AiModelInfo _modelInfo;
  late Map<String, dynamic> _currentSettings;
  late ChatStorageService _storage;
  late ModelManager _modelManager;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _storage = Get.find<ChatStorageService>();
    _modelManager = Get.find<ModelManager>();
    _loadModelInfo();
  }

  Future<void> _loadModelInfo() async {
    setState(() => _isLoading = true);
    try {
      _modelInfo = _modelManager.catalog.firstWhere(
        (m) => m.filename == widget.modelFilename,
        orElse: () => AiModelInfo.fromLocalFilename(widget.modelFilename),
      );
      _currentSettings = _storage.getAdjustedSettings(widget.modelFilename, _modelInfo);
    } catch (e) {
      Get.snackbar('Error', 'Failed to load model info: $e', snackPosition: SnackPosition.BOTTOM);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Model Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('Settings for ${_modelInfo.name}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Model Info Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Model: ${_modelInfo.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('File: ${_modelInfo.filename}'),
                    Text('Min RAM: ${_modelInfo.minRamGb} GB'),
                    Text('Capabilities: ${_modelInfo.capabilities.join(", ")}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Context Size Setting
            const Text('Context Size', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(
              'Minimum: ${_modelInfo.minContextSize}, Maximum: ${_modelInfo.maxContextSize}',
              style: const TextStyle(color: Colors.grey),
            ),
            Slider(
              value: (_currentSettings['contextSize'] as int).toDouble(),
              min: _modelInfo.minContextSize.toDouble(),
              max: _modelInfo.maxContextSize.toDouble(),
              divisions: (_modelInfo.maxContextSize - _modelInfo.minContextSize) ~/ 1024,
              label: 'Context Size: ${_currentSettings['contextSize']}',
              onChanged: (value) {
                setState(() {
                  _currentSettings['contextSize'] = value.toInt();
                });
              },
            ),
            Text('Selected: ${_currentSettings['contextSize']}'),
            const SizedBox(height: 20),

            // Token Limit Setting
            const Text('Token Limit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(
              'Minimum: ${_modelInfo.minTokens}',
              style: const TextStyle(color: Colors.grey),
            ),
            Slider(
              value: (_currentSettings['tokenLimit'] as int).toDouble(),
              min: _modelInfo.minTokens.toDouble(),
              max: (_modelInfo.minTokens * 2).toDouble(),
              divisions: _modelInfo.minTokens ~/ 1000,
              label: 'Token Limit: ${_currentSettings['tokenLimit']}',
              onChanged: (value) {
                setState(() {
                  _currentSettings['tokenLimit'] = value.toInt();
                });
              },
            ),
            Text('Selected: ${_currentSettings['tokenLimit']}'),
            const SizedBox(height: 20),

            // CPU Threads Setting
            const Text('CPU Threads', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(
              'Recommended: 2-4 for most devices',
              style: const TextStyle(color: Colors.grey),
            ),
            Slider(
              value: (_currentSettings['cpuThreads'] as int? ?? 2).toDouble(),
              min: 1,
              max: 16,
              divisions: 15,
              label: 'Threads: ${_currentSettings['cpuThreads'] ?? 2}',
              onChanged: (value) {
                setState(() {
                  _currentSettings['cpuThreads'] = value.toInt();
                });
              },
            ),
            Text('Selected: ${_currentSettings['cpuThreads'] ?? 2}'),
            const SizedBox(height: 20),

            // Batch Size Setting
            const Text('Batch Size', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(
              'Higher values may improve speed but use more memory',
              style: const TextStyle(color: Colors.grey),
            ),
            Slider(
              value: (_currentSettings['batchSize'] as int? ?? 128).toDouble(),
              min: 32,
              max: 1024,
              divisions: 10,
              label: 'Batch Size: ${_currentSettings['batchSize'] ?? 128}',
              onChanged: (value) {
                setState(() {
                  _currentSettings['batchSize'] = value.toInt();
                });
              },
            ),
            Text('Selected: ${_currentSettings['batchSize'] ?? 128}'),
            const SizedBox(height: 30),

            // Save Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  _storage.saveModelSettings(widget.modelFilename, _currentSettings);
                  Get.snackbar('Success', 'Model settings saved!', snackPosition: SnackPosition.BOTTOM);
                },
                child: const Text('Save Settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}