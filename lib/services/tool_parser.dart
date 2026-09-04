/// Detects and extracts tool-call requests from raw model output.
///
/// Format the model is instructed (via system prompt) to use:
///
/// GitHub Tools:
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
/// File System Tools:
///   [[READ_FILE]]
///   path: /path/to/local/file.txt
///   [[/READ_FILE]]
///
///   [[WRITE_FILE]]
///   path: /path/to/local/file.txt
///   ---
///   file content here
///   [[/WRITE_FILE]]
///
///   [[LIST_FILES]]
///   path: /path/to/directory
///   [[/LIST_FILES]]
///
/// Utility Tools:
///   [[CALCULATE]]
///   expression: (5 + 3) * 2
///   [[/CALCULATE]]
///
///   [[DATETIME]]
///   [[/DATETIME]]
///
///   [[SYSTEM_INFO]]
///   [[/SYSTEM_INFO]]
///
///   [[CLIPBOARD_COPY]]
///   text: text to copy
///   [[/CLIPBOARD_COPY]]
///
///   [[WEB_SEARCH]]
///   query: what is flutter
///   [[/WEB_SEARCH]]
///
/// This is a plain, greppable block format rather than JSON because small
/// local GGUF models are noticeably more reliable at reproducing a fixed
/// text template exactly than at producing valid, correctly-escaped JSON,
/// especially when the payload is multi-line source code.
///
/// IMPORTANT: parsing a request here does not execute it. The caller
/// (ChatController) must always route write operations through a
/// user-confirmation UI before executing.
library;

enum ToolKind {
  // GitHub tools
  githubWriteFile,
  githubReadFile,
  githubListIssues,
  
  // File system tools
  readFile,
  writeFile,
  listFiles,
  
  // Utility tools
  calculate,
  dateTime,
  systemInfo,
  clipboardCopy,
  webSearch,
  
  none
}

class ToolRequest {
  final ToolKind kind;
  final String? path;
  final String? message;
  final String? content;
  final String? expression;
  final String? query;
  final String? text;

  ToolRequest({
    required this.kind,
    this.path,
    this.message,
    this.content,
    this.expression,
    this.query,
    this.text,
  });

  static final _none = ToolRequest(kind: ToolKind.none);
  
  // Helper to check if this is a write operation that needs confirmation
  bool get requiresConfirmation {
    return kind == ToolKind.writeFile || 
           kind == ToolKind.githubWriteFile ||
           kind == ToolKind.clipboardCopy;
  }
  
  // Helper to check if this is a read-only operation
  bool get isReadOnly {
    return kind == ToolKind.readFile || 
           kind == ToolKind.listFiles ||
           kind == ToolKind.githubReadFile ||
           kind == ToolKind.githubListIssues ||
           kind == ToolKind.calculate ||
           kind == ToolKind.dateTime ||
           kind == ToolKind.systemInfo ||
           kind == ToolKind.webSearch;
  }
}

class ToolParser {
  // GitHub Tools
  static final _githubWriteRe = RegExp(
    r'\[\[GITHUB_WRITE_FILE\]\]\s*'
    r'path:\s*(.+?)\s*\n'
    r'message:\s*(.+?)\s*\n'
    r'---\s*\n'
    r'([\s\S]*?)'
    r'\[\[/GITHUB_WRITE_FILE\]\]',
    multiLine: true,
  );

  static final _githubReadRe = RegExp(
    r'\[\[GITHUB_READ_FILE\]\]\s*'
    r'path:\s*(.+?)\s*\n'
    r'\[\[/GITHUB_READ_FILE\]\]',
    multiLine: true,
  );

  static final _githubListIssuesRe = RegExp(r'\[\[GITHUB_LIST_ISSUES\]\]');

  // File System Tools
  static final _readFileRe = RegExp(
    r'\[\[READ_FILE\]\]\s*'
    r'path:\s*(.+?)\s*\n'
    r'\[\[/READ_FILE\]\]',
    multiLine: true,
  );

  static final _writeFileRe = RegExp(
    r'\[\[WRITE_FILE\]\]\s*'
    r'path:\s*(.+?)\s*\n'
    r'---\s*\n'
    r'([\s\S]*?)'
    r'\[\[/WRITE_FILE\]\]',
    multiLine: true,
  );

  static final _listFilesRe = RegExp(
    r'\[\[LIST_FILES\]\]\s*'
    r'path:\s*(.+?)\s*\n'
    r'\[\[/LIST_FILES\]\]',
    multiLine: true,
  );

  // Utility Tools
  static final _calculateRe = RegExp(
    r'\[\[CALCULATE\]\]\s*'
    r'expression:\s*(.+?)\s*\n'
    r'\[\[/CALCULATE\]\]',
    multiLine: true,
  );

  static final _dateTimeRe = RegExp(r'\[\[DATETIME\]\]\s*\n?\[\[/DATETIME\]\]');
  
  static final _systemInfoRe = RegExp(r'\[\[SYSTEM_INFO\]\]\s*\n?\[\[/SYSTEM_INFO\]\]');
  
  static final _clipboardCopyRe = RegExp(
    r'\[\[CLIPBOARD_COPY\]\]\s*'
    r'text:\s*(.+?)\s*\n'
    r'\[\[/CLIPBOARD_COPY\]\]',
    multiLine: true,
  );

  static final _webSearchRe = RegExp(
    r'\[\[WEB_SEARCH\]\]\s*'
    r'query:\s*(.+?)\s*\n'
    r'\[\[/WEB_SEARCH\]\]',
    multiLine: true,
  );

  /// Scans [text] (the full assistant message) for exactly one tool-call
  /// block. Returns ToolRequest(kind: ToolKind.none) if nothing recognized.
  /// If multiple blocks are present, only the first match is honored —
  /// intentionally conservative, one action per turn.
  static ToolRequest parse(String text) {
    // GitHub Tools
    final githubWriteMatch = _githubWriteRe.firstMatch(text);
    if (githubWriteMatch != null) {
      return ToolRequest(
        kind: ToolKind.githubWriteFile,
        path: githubWriteMatch.group(1)?.trim(),
        message: githubWriteMatch.group(2)?.trim(),
        content: githubWriteMatch.group(3),
      );
    }

    final githubReadMatch = _githubReadRe.firstMatch(text);
    if (githubReadMatch != null) {
      return ToolRequest(
        kind: ToolKind.githubReadFile,
        path: githubReadMatch.group(1)?.trim(),
      );
    }

    if (_githubListIssuesRe.hasMatch(text)) {
      return ToolRequest(kind: ToolKind.githubListIssues);
    }

    // File System Tools
    final writeMatch = _writeFileRe.firstMatch(text);
    if (writeMatch != null) {
      return ToolRequest(
        kind: ToolKind.writeFile,
        path: writeMatch.group(1)?.trim(),
        content: writeMatch.group(2),
      );
    }

    final readMatch = _readFileRe.firstMatch(text);
    if (readMatch != null) {
      return ToolRequest(
        kind: ToolKind.readFile,
        path: readMatch.group(1)?.trim(),
      );
    }

    final listFilesMatch = _listFilesRe.firstMatch(text);
    if (listFilesMatch != null) {
      return ToolRequest(
        kind: ToolKind.listFiles,
        path: listFilesMatch.group(1)?.trim(),
      );
    }

    // Utility Tools
    final calculateMatch = _calculateRe.firstMatch(text);
    if (calculateMatch != null) {
      return ToolRequest(
        kind: ToolKind.calculate,
        expression: calculateMatch.group(1)?.trim(),
      );
    }

    if (_dateTimeRe.hasMatch(text)) {
      return ToolRequest(kind: ToolKind.dateTime);
    }

    if (_systemInfoRe.hasMatch(text)) {
      return ToolRequest(kind: ToolKind.systemInfo);
    }

    final clipboardMatch = _clipboardCopyRe.firstMatch(text);
    if (clipboardMatch != null) {
      return ToolRequest(
        kind: ToolKind.clipboardCopy,
        text: clipboardMatch.group(1)?.trim(),
      );
    }

    final webSearchMatch = _webSearchRe.firstMatch(text);
    if (webSearchMatch != null) {
      return ToolRequest(
        kind: ToolKind.webSearch,
        query: webSearchMatch.group(1)?.trim(),
      );
    }

    return ToolRequest(kind: ToolKind.none);
  }

  /// Strips any recognized tool-call block out of [text], so the raw
  /// template syntax is never shown to the user in the chat bubble.
  static String stripToolBlocks(String text) {
    return text
        // GitHub tools
        .replaceAll(_githubWriteRe, '')
        .replaceAll(_githubReadRe, '')
        .replaceAll(_githubListIssuesRe, '')
        // File system tools
        .replaceAll(_writeFileRe, '')
        .replaceAll(_readFileRe, '')
        .replaceAll(_listFilesRe, '')
        // Utility tools
        .replaceAll(_calculateRe, '')
        .replaceAll(_dateTimeRe, '')
        .replaceAll(_systemInfoRe, '')
        .replaceAll(_clipboardCopyRe, '')
        .replaceAll(_webSearchRe, '')
        .trim();
  }

  /// System prompt fragment teaching the model the exact format for GitHub tools only.
  /// Use ToolService.toolInstructions for all tools.
  /// Append this to the user's system prompt when tools are enabled.
  static const String toolInstructions = '''
You have access to several tools you can use to assist the user. \
ONLY use a tool when explicitly asked or when it directly helps answer the user's request. \
Never invent file paths, content, or data you have not been shown.

=== GitHub Tools (if repository is configured) ===

To read a GitHub file:
[[GITHUB_READ_FILE]]
path: <path in repo>
[[/GITHUB_READ_FILE]]

To propose writing a GitHub file (USER MUST APPROVE before execution):
[[GITHUB_WRITE_FILE]]
path: <path in repo>
message: <short commit message>
---
<full new file content>
[[/GITHUB_WRITE_FILE]]

To list open GitHub issues:
[[GITHUB_LIST_ISSUES]]
[[/GITHUB_LIST_ISSUES]]

=== File System Tools ===

To read a local file:
[[READ_FILE]]
path: <absolute path>
[[/READ_FILE]]

To write a local file (USER MUST APPROVE):
[[WRITE_FILE]]
path: <absolute path>
---
<file content>
[[/WRITE_FILE]]

To list files in a directory:
[[LIST_FILES]]
path: <directory path>
[[/LIST_FILES]]

=== Utility Tools ===

To calculate a mathematical expression:
[[CALCULATE]]
expression: <math expression, e.g., (5 + 3) * 2>
[[/CALCULATE]]

To get current date and time:
[[DATETIME]]
[[/DATETIME]]

To get system information (platform, RAM, etc.):
[[SYSTEM_INFO]]
[[/SYSTEM_INFO]]

To copy text to clipboard:
[[CLIPBOARD_COPY]]
text: <text to copy>
[[/CLIPBOARD_COPY]]

To search the web for information:
[[WEB_SEARCH]]
query: <search query>
[[/WEB_SEARCH]]

IMPORTANT: Always show the user what action you are taking before using a tool. \
For write operations (GITHUB_WRITE_FILE, WRITE_FILE, CLIPBOARD_COPY), the user MUST explicitly approve. \
For read-only operations, you can proceed directly.
''';
}
