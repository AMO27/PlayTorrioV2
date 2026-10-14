import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart';

/// Tiny file log so a failure can be read afterwards instead of retyped.
/// On Windows it writes `playtorrio-debug.log` next to the app's exe; on other
/// platforms it does nothing. It never throws and keeps itself under ~400 KB.
class DebugLog {
  DebugLog._();

  static const int _maxBytes = 400 * 1024;
  static File? _file;

  static File? _open() {
    if (!Platform.isWindows) return null;
    return _file ??= File(
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}playtorrio-debug.log');
  }

  static bool _installed = false;

  // Lines the app prints through debugPrint that look like a problem.
  static final RegExp _looksLikeProblem = RegExp(
      r'error|exception|fail|timed out|timeout|refused|blocked|denied|'
      r'not found|could not|couldn.t|unable|crash|fatal|invalid|unauthorized|'
      r'forbidden|\b(4\d\d|5\d\d)\b',
      caseSensitive: false);

  /// Sends every uncaught error, every Flutter framework error and every
  /// debugPrint line that looks like a problem to the log file, for the whole
  /// app (music, anime, movies, books, games and the rest). Call once at start.
  static void install() {
    if (_installed || !Platform.isWindows) return;
    _installed = true;
    write('app', 'started');

    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      write('flutter',
          '${details.exceptionAsString()} | ${_shortStack(details.stack)}');
      if (previousFlutterHandler != null) {
        previousFlutterHandler(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    final previousDispatcherHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      write('uncaught', '$error | ${_shortStack(stack)}');
      return previousDispatcherHandler?.call(error, stack) ?? false;
    };

    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && _looksLikeProblem.hasMatch(message)) {
        write('log', message.replaceAll('\n', ' | '));
      }
      previousDebugPrint(message, wrapWidth: wrapWidth);
    };
  }

  static String _shortStack(StackTrace? st) {
    if (st == null) return '';
    return st.toString().split('\n').take(4).join(' <- ');
  }

  static void write(String area, String message) {
    try {
      final f = _open();
      if (f == null) return;
      if (f.existsSync() && f.lengthSync() > _maxBytes) {
        // Keep the newest half.
        final text = f.readAsStringSync();
        f.writeAsStringSync(text.substring(text.length ~/ 2));
      }
      final t = DateTime.now().toIso8601String();
      f.writeAsStringSync('$t [$area] $message\n',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never break the app.
    }
  }
}
