import 'package:flutter/foundation.dart';

/// Centralized logging utility for the application
/// Provides consistent logging across different build modes
class Logger {
  static const String _tag = 'LuciMobile';
  static const int _maxEntries = 300;
  static final List<String> _entries = [];

  /// Log debug messages.
  static void debug(String message) {
    _record('DEBUG', message);
  }

  /// Log info messages
  static void info(String message) {
    _record('INFO', message);
  }

  /// Log warning messages
  static void warning(String message) {
    _record('WARNING', message);
  }

  /// Log error messages with optional stack trace
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    _record('ERROR', message, error, stackTrace);
  }

  /// Log exceptions with context
  static void exception(
    String context,
    Object exception,
    StackTrace stackTrace,
  ) {
    error('$context: $exception', exception, stackTrace);
  }

  static String exportLog() {
    if (_entries.isEmpty) {
      return 'No debug log entries captured for this app session.';
    }
    return _entries.join('\n');
  }

  static void clear() {
    _entries.clear();
  }

  static void _record(
    String level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    final buffer = StringBuffer(
      '[${DateTime.now().toIso8601String()}] [$_tag] $level: '
      '${_sanitize(message)}',
    );

    if (error != null) {
      buffer.write('\n[$_tag] Exception: ${_sanitize(error.toString())}');
    }
    if (stackTrace != null) {
      buffer.write(
        '\n[$_tag] Stack trace:\n${_sanitize(stackTrace.toString())}',
      );
    }

    final entry = buffer.toString();
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }

    if (kDebugMode) {
      debugPrint(entry);
    }
  }

  static String _sanitize(String value) {
    var sanitized = value;
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'(luci_password=)[^&\s]+', caseSensitive: false),
      (match) => '${match[1]}<redacted>',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'("(?:password|sysauth|token)"\s*:\s*")[^"]*(")',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<redacted>${match[2]}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(password|sysauth|token)\s*[:=]\s*[^\s,}]+',
        caseSensitive: false,
      ),
      (match) => '${match[1]}=<redacted>',
    );
    return sanitized;
  }
}
