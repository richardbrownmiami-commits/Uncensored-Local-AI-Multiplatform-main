/// Detects and extracts a GitHub tool-call request from raw model output.
///
/// Format the model is instructed (via system prompt) to use:
///
///   [[GITHUB_WRITE_FILE]]
///   path: lib/main.dart
///   message: fix null check bug
///   ---
///   <full new file content here>
///   [[/GITHUB_WRITE_FILE]]
///
///   [[GITHUB_READ_FILE]]
///   path: lib/main.dart
///   [[/GITHUB_READ_FILE]]
///
///   [[GITHUB_LIST_ISSUES]]
///   [[/GITHUB_LIST_ISSUES]]
///
/// This is a plain, greppable block format rather than JSON because small
/// local GGUF models are noticeably more reliable at reproducing a fixed
/// text template exactly than at producing valid, correctly-escaped JSON,
/// especially when the payload is multi-line source code.
///
/// IMPORTANT: parsing a request here does not execute it. The caller
/// (ChatController) must always route ToolRequest.write through a
/// user-confirmation UI before calling GitHubService.commitFile().
library;

enum ToolKind { writeFile, readFile, listIssues, none }

class ToolRequest {
  final ToolKind kind;
  final String? path;
  final String? message;
  final String? content;

  ToolRequest({
    required this.kind,
    this.path,
    this.message,
    this.content,
  });

  static final _none = ToolRequest(kind: ToolKind.none);
}

class ToolParser {
  static final _writeRe = RegExp(
    r'\[\[GITHUB_WRITE_FILE\]\]\s*'
    r'path:\s*(.+?)\s*\n'
    r'message:\s*(.+?)\s*\n'
    r'---\s*\n'
    r'([\s\S]*?)'
    r'\[\[/GITHUB_WRITE_FILE\]\]',
    multiLine: true,
  );

  static final _readRe = RegExp(
    r'\[\[GITHUB_READ_FILE\]\]\s*'
    r'path:\s*(.+?)\s*\n'
    r'\[\[/GITHUB_READ_FILE\]\]',
    multiLine: true,
  );

  static final _listIssuesRe = RegExp(r'\[\[GITHUB_LIST_ISSUES\]\]');

  /// Scans [text] (the full assistant message) for exactly one tool-call
  /// block. Returns ToolRequest(kind: ToolKind.none) if nothing recognized.
  /// If multiple blocks are present, only the first match is honored —
  /// intentionally conservative, one action per turn.
  static ToolRequest parse(String text) {
    final writeMatch = _writeRe.firstMatch(text);
    if (writeMatch != null) {
      return ToolRequest(
        kind: ToolKind.writeFile,
        path: writeMatch.group(1)?.trim(),
        message: writeMatch.group(2)?.trim(),
        content: writeMatch.group(3),
      );
    }

    final readMatch = _readRe.firstMatch(text);
    if (readMatch != null) {
      return ToolRequest(
        kind: ToolKind.readFile,
        path: readMatch.group(1)?.trim(),
      );
    }

    if (_listIssuesRe.hasMatch(text)) {
      return ToolRequest(kind: ToolKind.listIssues);
    }

    return ToolRequest(kind: ToolKind.none);
  }

  /// Strips any recognized tool-call block out of [text], so the raw
  /// template syntax is never shown to the user in the chat bubble.
  static String stripToolBlocks(String text) {
    return text
        .replaceAll(_writeRe, '')
        .replaceAll(_readRe, '')
        .replaceAll(_listIssuesRe, '')
        .trim();
  }

  /// System prompt fragment teaching the model the exact format.
  /// Append this to the user's system prompt only when GitHub is configured.
  static const String toolInstructions = '''
You can interact with one GitHub repository using these exact formats. \
Use a block ONLY when the user explicitly asks for a GitHub action. \
Never invent file paths or content you have not been shown.

To read a file:
[[GITHUB_READ_FILE]]
path: <path in repo>
[[/GITHUB_READ_FILE]]

To propose writing/committing a file (the user must approve before anything \
is sent to GitHub, so always show a brief plain-language summary of the \
change before the block):
[[GITHUB_WRITE_FILE]]
path: <path in repo>
message: <short commit message>
---
<the full new file content>
[[/GITHUB_WRITE_FILE]]

To list open issues:
[[GITHUB_LIST_ISSUES]]
[[/GITHUB_LIST_ISSUES]]
''';
}
