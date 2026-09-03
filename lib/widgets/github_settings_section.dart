import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../theme/app_colors.dart';
import '../services/github_service.dart';

/// GitHub connection settings — PAT, owner, repo.
/// Drop this widget into settings_screen.dart's section list.
class GithubSettingsSection extends StatefulWidget {
  const GithubSettingsSection({super.key});

  @override
  State<GithubSettingsSection> createState() => _GithubSettingsSectionState();
}

class _GithubSettingsSectionState extends State<GithubSettingsSection> {
  final _github = Get.find<GitHubService>();
  final _patCtrl = TextEditingController();
  final _ownerCtrl = TextEditingController();
  final _repoCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ownerCtrl.text = _github.owner ?? '';
    _repoCtrl.text = _github.repo ?? '';
    // PAT is never re-displayed once saved — only re-entered to replace it.
  }

  @override
  void dispose() {
    _patCtrl.dispose();
    _ownerCtrl.dispose();
    _repoCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_ownerCtrl.text.trim().isEmpty ||
        _repoCtrl.text.trim().isEmpty ||
        _patCtrl.text.trim().isEmpty) {
      Get.snackbar('Missing info', 'Enter PAT, owner, and repo name.',
          snackPosition: SnackPosition.BOTTOM);
      return;
    }
    setState(() => _saving = true);
    await _github.configure(
      pat: _patCtrl.text.trim(),
      owner: _ownerCtrl.text.trim(),
      repo: _repoCtrl.text.trim(),
    );
    _patCtrl.clear();
    setState(() => _saving = false);
    Get.snackbar('Saved', 'GitHub connected to ${_github.owner}/${_github.repo}',
        snackPosition: SnackPosition.BOTTOM);
  }

  Future<void> _disconnect() async {
    await _github.clearCredentials();
    _ownerCtrl.clear();
    _repoCtrl.clear();
    setState(() {});
    Get.snackbar('Disconnected', 'GitHub credentials removed.',
        snackPosition: SnackPosition.BOTTOM);
  }

  InputDecoration _decoration(BuildContext context, String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: context.textD),
      filled: true,
      fillColor: context.bgInput,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: context.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: context.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _github.isConfigured
              ? 'Connected to ${_github.owner}/${_github.repo}. The AI can propose file reads, writes, and issue lookups for this repo — every write still needs your approval in a popup.'
              : 'Connect one repository. The AI will only ever act on this repo, and every write (commit) requires your approval before it happens.',
          style: TextStyle(fontSize: 12, color: context.textD),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ownerCtrl,
          style: TextStyle(fontSize: 14, color: context.text),
          decoration: _decoration(context, 'GitHub username or org (owner)'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _repoCtrl,
          style: TextStyle(fontSize: 14, color: context.text),
          decoration: _decoration(context, 'Repository name'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _patCtrl,
          obscureText: true,
          style: TextStyle(fontSize: 14, color: context.text),
          decoration: _decoration(
            context,
            _github.isConfigured
                ? 'New token (leave blank to keep current)'
                : 'GitHub fine-grained token (repo-scoped, contents: read/write)',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.link_rounded, size: 16),
              label: Text(_saving ? 'Saving...' : 'Save'),
            ),
            if (_github.isConfigured) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _disconnect,
                style: TextButton.styleFrom(foregroundColor: AppColors.red),
                icon: const Icon(Icons.link_off_rounded, size: 16),
                label: const Text('Disconnect'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
