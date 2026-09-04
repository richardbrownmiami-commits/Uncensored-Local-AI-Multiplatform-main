import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;

import 'tool_parser.dart';
import 'log_service.dart';

/// Service for executing various tools requested by the AI model.
/// Handles file system operations, calculations, system info, clipboard, and web search.
class ToolService extends GetxService {
  LogService? _log;

  ToolService() {
    try {
      _log = Get.find<LogService>();
    } catch (_) {
      _log = null;
    }
  }

  /// Execute a tool request and return the result as a string.
  /// Returns null if the tool requires user confirmation (write operations).
  /// Throws an exception if the tool execution fails.
  Future<String?> executeTool(ToolRequest request) async {
    _log?.info('Executing tool: ${request.kind}', source: 'ToolService');

    switch (request.kind) {
      // GitHub tools - delegated to GitHubService
      case ToolKind.githubWriteFile:
      case ToolKind.githubReadFile:
      case ToolKind.githubListIssues:
        throw Exception('GitHub tools should be handled by GitHubService');

      // File System Tools
      case ToolKind.readFile:
        return await _readFile(request.path);
      case ToolKind.writeFile:
        throw Exception('Write operations require user confirmation');
      case ToolKind.listFiles:
        return await _listFiles(request.path);

      // Utility Tools
      case ToolKind.calculate:
        return await _calculate(request.expression);
      case ToolKind.dateTime:
        return await _getDateTime();
      case ToolKind.systemInfo:
        return await _getSystemInfo();
      case ToolKind.clipboardCopy:
        throw Exception('Clipboard copy requires user confirmation');
      case ToolKind.webSearch:
        return await _webSearch(request.query);

      case ToolKind.none:
        return null;
    }
  }

  /// Execute a confirmed tool (user has approved)
  Future<String> executeConfirmedTool(ToolRequest request) async {
    _log?.info('Executing confirmed tool: ${request.kind}', source: 'ToolService');

    switch (request.kind) {
      case ToolKind.writeFile:
        return await _writeFile(request.path!, request.content ?? '');
      case ToolKind.githubWriteFile:
        throw Exception('GitHub write should be handled by GitHubService');
      case ToolKind.clipboardCopy:
        return await _copyToClipboard(request.text ?? '');
      default:
        throw Exception('Tool ${request.kind} does not require confirmation');
    }
  }

  // ========== File System Tools ==========

  /// Read a file from the local file system
  Future<String> _readFile(String? path) async {
    if (path == null || path.isEmpty) {
      throw Exception('No path provided');
    }

    // Security: only allow reading from app directories
    if (!await _isSafePath(path)) {
      throw Exception('Cannot read from that location for security reasons');
    }

    final file = File(path);
    if (!await file.exists()) {
      throw Exception('File not found: $path');
    }

    try {
      final content = await file.readAsString();
      _log?.info('Read file: $path (${content.length} bytes)', source: 'ToolService');
      
      // Limit the size of displayed content
      if (content.length > 100000) {
        return 'File is too large to display (${content.length} bytes). '
               'First 100KB:\n\n${content.substring(0, 100000)}...';
      }
      return content;
    } catch (e) {
      throw Exception('Failed to read file: $e');
    }
  }

  /// Write a file to the local file system
  Future<String> _writeFile(String path, String content) async {
    if (path.isEmpty) {
      throw Exception('No path provided');
    }

    // Security: only allow writing to app directories
    if (!await _isSafePath(path)) {
      throw Exception('Cannot write to that location for security reasons');
    }

    try {
      final file = File(path);
      // Create parent directories if they don't exist
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      
      await file.writeAsString(content);
      _log?.info('Wrote file: $path (${content.length} bytes)', source: 'ToolService');
      return 'File written successfully: $path (${content.length} bytes)';
    } catch (e) {
      throw Exception('Failed to write file: $e');
    }
  }

  /// List files in a directory
  Future<String> _listFiles(String? path) async {
    if (path == null || path.isEmpty) {
      // Default to app documents directory
      final dir = await getApplicationDocumentsDirectory();
      path = dir.path;
    }

    // Security: only allow listing from app directories
    if (!await _isSafePath(path)) {
      throw Exception('Cannot list files from that location for security reasons');
    }

    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        throw Exception('Directory not found: $path');
      }

      final entities = await dir.list().toList();
      final files = <String>[];
      final dirs = <String>[];

      for (final entity in entities) {
        final name = entity.path.split('/').last;
        if (entity is File) {
          final size = await entity.length();
          files.add('$name (${_formatBytes(size)})');
        } else if (entity is Directory) {
          dirs.add('$name/');
        }
      }

      final result = StringBuffer();
      result.writeln('Directory: $path');
      result.writeln('');
      
      if (dirs.isNotEmpty) {
        result.writeln('Directories:');
        for (final d in dirs) {
          result.writeln('  $d');
        }
        result.writeln('');
      }

      if (files.isNotEmpty) {
        result.writeln('Files:');
        for (final f in files) {
          result.writeln('  $f');
        }
      } else {
        result.writeln('(no files)');
      }

      return result.toString();
    } catch (e) {
      throw Exception('Failed to list files: $e');
    }
  }

  /// Check if a path is safe to access (within app directories)
  Future<bool> _isSafePath(String? path) async {
    if (path == null || path.isEmpty) return false;

    // Get app directories
    final appDir = await getApplicationDocumentsDirectory();
    final appSupportDir = await getApplicationSupportDirectory();
    final appCacheDir = await getTemporaryDirectory();

    // Allow access to app directories and their subdirectories
    final allowedRoots = [
      appDir.path,
      appSupportDir.path,
      appCacheDir.path,
    ];

    // Normalize path
    final normalized = path.replaceAll(r'\', '/');

    // Check if path starts with any allowed root
    for (final root in allowedRoots) {
      final normalizedRoot = root.replaceAll(r'\', '/');
      if (normalized.startsWith(normalizedRoot)) {
        return true;
      }
    }

    return false;
  }

  // ========== Utility Tools ==========

  /// Calculate a mathematical expression
  Future<String> _calculate(String? expression) async {
    if (expression == null || expression.isEmpty) {
      throw Exception('No expression provided');
    }

    try {
      // Sanitize expression - only allow math operations
      final sanitized = expression.replaceAll(RegExp(r'[^0-9\+\-\*\/\.\(\)\s]'), '');
      
      if (sanitized.isEmpty) {
        throw Exception('Invalid expression');
      }

      // Use a simple expression evaluator
      final result = _evaluateExpression(sanitized);
      return 'Result: $result';
    } catch (e) {
      throw Exception('Failed to calculate: $e');
    }
  }

  /// Simple expression evaluator (supports +, -, *, /, parentheses)
  double _evaluateExpression(String expression) {
    // Remove whitespace
    expression = expression.replaceAll('\s', '');
    
    // Handle parentheses by recursive evaluation
    final parenStart = expression.lastIndexOf('(');
    if (parenStart != -1) {
      final parenEnd = expression.indexOf(')', parenStart);
      if (parenEnd == -1) {
        throw Exception('Mismatched parentheses');
      }
      final inner = expression.substring(parenStart + 1, parenEnd);
      final innerResult = _evaluateExpression(inner);
      expression = expression.replaceRange(
        parenStart, 
        parenEnd + 1, 
        innerResult.toString()
      );
      return _evaluateExpression(expression);
    }

    // Evaluate multiplication and division first
    final mulDivMatch = RegExp(r'(-?\d+\.?\d*)([\*\/])(-?\d+\.?\d*)').firstMatch(expression);
    if (mulDivMatch != null) {
      final left = double.parse(mulDivMatch.group(1)!);
      final op = mulDivMatch.group(2)!;
      final right = double.parse(mulDivMatch.group(3)!);
      final result = op == '*' ? left * right : left / right;
      final newExpr = expression.replaceRange(
        mulDivMatch.start,
        mulDivMatch.end,
        result.toString()
      );
      return _evaluateExpression(newExpr);
    }

    // Evaluate addition and subtraction
    final addSubMatch = RegExp(r'(-?\d+\.?\d*)([\+\-])(-?\d+\.?\d*)').firstMatch(expression);
    if (addSubMatch != null) {
      final left = double.parse(addSubMatch.group(1)!);
      final op = addSubMatch.group(2)!;
      final right = double.parse(addSubMatch.group(3)!);
      final result = op == '+' ? left + right : left - right;
      final newExpr = expression.replaceRange(
        addSubMatch.start,
        addSubMatch.end,
        result.toString()
      );
      return _evaluateExpression(newExpr);
    }

    // If no operations, it should be a number
    return double.parse(expression);
  }

  /// Get current date and time
  Future<String> _getDateTime() async {
    final now = DateTime.now();
    return 'Current date and time: ${now.toLocal()} (${now.timeZoneName})';
  }

  /// Get system information
  Future<String> _getSystemInfo() async {
    final info = StringBuffer();
    info.writeln('=== System Information ===');
    info.writeln('');

    // Platform
    info.writeln('Platform: ${Platform.operatingSystem}');
    info.writeln('Platform Version: ${Platform.operatingSystemVersion}');
    info.writeln('');

    // Device info
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        info.writeln('Device: ${androidInfo.model}');
        info.writeln('Manufacturer: ${androidInfo.manufacturer}');
        info.writeln('Android Version: ${androidInfo.version.release}');
        info.writeln('SDK: ${androidInfo.version.sdkInt}');
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        info.writeln('Device: ${iosInfo.model}');
        info.writeln('System: ${iosInfo.systemName} ${iosInfo.systemVersion}');
      } else {
        info.writeln('Device: ${Platform.localHostname}');
      }
      info.writeln('');
    } catch (e) {
      info.writeln('Device info: Not available');
      info.writeln('');
    }

    // CPU
    info.writeln('CPU Cores: ${Platform.numberOfProcessors}');
    info.writeln('');

    // Memory (approximate)
    // Note: This requires additional permissions on some platforms
    info.writeln('Note: RAM information requires platform-specific APIs');
    info.writeln('');

    // App info
    info.writeln('App: Uncensored Local AI');
    info.writeln('');

    return info.toString();
  }

  /// Copy text to clipboard
  Future<String> _copyToClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return 'Copied to clipboard: ${text.length > 50 ? text.substring(0, 50) + '...' : text}';
    } catch (e) {
      throw Exception('Failed to copy to clipboard: $e');
    }
  }

  /// Search the web
  Future<String> _webSearch(String? query) async {
    if (query == null || query.isEmpty) {
      throw Exception('No search query provided');
    }

    try {
      // Use a simple web search - in production, consider using a proper search API
      // For now, we'll use a basic approach with a note about limitations
      
      // Note: This is a placeholder. For a real implementation, you would:
      // 1. Use a search API (Google Custom Search, Bing, etc.)
      // 2. Or use a web scraping approach (with proper rate limiting)
      // 3. Or integrate with a knowledge base
      
      return 'Web search for "$query":\n\n'
             'Note: Web search functionality requires API configuration. '
             'For now, please search manually in your browser.';
    } catch (e) {
      throw Exception('Failed to perform web search: $e');
    }
  }

  // ========== Helpers ==========

  /// Format bytes to human-readable string
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
