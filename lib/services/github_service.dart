import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// GitHub integration service.
///
/// Design notes (do not remove these constraints when editing):
/// - The PAT is stored in the OS secure storage (Android Keystore), never in
///   Hive/SharedPreferences, and never printed to logs.
/// - This service exposes actions only — it does NOT decide when to call
///   them. The chat/tool-calling layer must always route a proposed action
///   through a user-facing confirm step (see PendingGitHubAction below)
///   before calling commitFile() or any other write method.
/// - Token is scoped by the user to a single owner/repo, entered in Settings.
///   This service never touches any repo other than the one configured.
class GitHubService extends GetxService {
  static const _storage = FlutterSecureStorage();
  static const _keyPat = 'github_pat';
  static const _keyOwner = 'github_owner';
  static const _keyRepo = 'github_repo';

  String? _pat;
  String? _owner;
  String? _repo;

  bool get isConfigured => _pat != null && _owner != null && _repo != null;
  String? get owner => _owner;
  String? get repo => _repo;

  Future<GitHubService> init() async {
    _pat = await _storage.read(key: _keyPat);
    _owner = await _storage.read(key: _keyOwner);
    _repo = await _storage.read(key: _keyRepo);
    return this;
  }

  /// Save connection details. Call this from the Settings screen only.
  Future<void> configure({
    required String pat,
    required String owner,
    required String repo,
  }) async {
    await _storage.write(key: _keyPat, value: pat);
    await _storage.write(key: _keyOwner, value: owner);
    await _storage.write(key: _keyRepo, value: repo);
    _pat = pat;
    _owner = owner;
    _repo = repo;
  }

  Future<void> clearCredentials() async {
    await _storage.delete(key: _keyPat);
    await _storage.delete(key: _keyOwner);
    await _storage.delete(key: _keyRepo);
    _pat = null;
    _owner = null;
    _repo = null;
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_pat',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  void _assertConfigured() {
    if (!isConfigured) {
      throw StateError('GitHub is not configured. Set PAT/owner/repo in Settings first.');
    }
  }

  /// Read a file's text content. Read-only, safe to call without confirmation.
  Future<String> readFile(String path) async {
    _assertConfigured();
    final url = Uri.parse('https://api.github.com/repos/$_owner/$_repo/contents/$path');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode != 200) {
      throw Exception('GitHub read failed (${res.statusCode}): ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final content = data['content'] as String;
    return utf8.decode(base64.decode(content.replaceAll('\n', '')));
  }

  /// List open issues. Read-only, safe to call without confirmation.
  Future<List<Map<String, dynamic>>> listIssues({int perPage = 20}) async {
    _assertConfigured();
    final url = Uri.parse(
        'https://api.github.com/repos/$_owner/$_repo/issues?state=open&per_page=$perPage');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode != 200) {
      throw Exception('GitHub issues fetch failed (${res.statusCode}): ${res.body}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  /// Write/commit a file. DESTRUCTIVE — only call this after the user has
  /// approved the specific diff/content in a confirmation dialog. Never call
  /// this directly from a model-output parser without that step.
  Future<void> commitFile({
    required String path,
    required String content,
    required String commitMessage,
  }) async {
    _assertConfigured();
    final url = Uri.parse('https://api.github.com/repos/$_owner/$_repo/contents/$path');

    // Look up existing sha (required by GitHub API to update a file).
    String? sha;
    final getRes = await http.get(url, headers: _headers);
    if (getRes.statusCode == 200) {
      sha = (jsonDecode(getRes.body) as Map<String, dynamic>)['sha'] as String?;
    }

    final body = jsonEncode({
      'message': commitMessage,
      'content': base64Encode(utf8.encode(content)),
      if (sha != null) 'sha': sha,
    });

    final putRes = await http.put(url, headers: _headers, body: body);
    if (putRes.statusCode != 200 && putRes.statusCode != 201) {
      throw Exception('GitHub commit failed (${putRes.statusCode}): ${putRes.body}');
    }
  }
}

/// Represents an action the AI has proposed but not yet executed.
/// The chat UI should render this as an approve/cancel card.
class PendingGitHubAction {
  final String kind; // 'commitFile', for now
  final String path;
  final String newContent;
  final String? oldContent;
  final String commitMessage;

  PendingGitHubAction({
    required this.kind,
    required this.path,
    required this.newContent,
    required this.commitMessage,
    this.oldContent,
  });
}
