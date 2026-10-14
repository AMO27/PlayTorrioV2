import 'package:flutter/foundation.dart';

/// Remembers when YouTube has started refusing this internet connection
/// ("rate limited" or "confirm you're not a bot"), so the app stops hammering
/// it with retries, which only makes the block last longer.
class YoutubeBlock {
  YoutubeBlock._();

  static const Duration coolOff = Duration(minutes: 10);
  static DateTime? _until;
  static bool _watching = false;

  static final RegExp _signs = RegExp(
      r'RequestLimitExceededException|Sign in to confirm you.?re not a bot|'
      r'confirm you.?re not a bot',
      caseSensitive: false);

  static bool get isBlocked =>
      _until != null && DateTime.now().isBefore(_until!);

  static void markBlocked() {
    if (isBlocked) return;
    _until = DateTime.now().add(coolOff);
  }

  /// Clears the block (used by a manual "try again").
  static void clear() => _until = null;

  /// Plain-language message for the UI, or null when not blocked.
  static String? get notice {
    if (!isBlocked) return null;
    final mins = _until!.difference(DateTime.now()).inMinutes + 1;
    return 'YouTube is blocking this internet connection right now (it is '
        'rate-limiting it or asking for a bot check). Songs will work again in '
        'about $mins min, or sooner on another network such as a phone hotspot. '
        'Downloaded songs still play.';
  }

  /// Watches the app's log lines for the signs above. Call once at start.
  static void watch() {
    if (_watching) return;
    _watching = true;
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && _signs.hasMatch(message)) markBlocked();
      previous(message, wrapWidth: wrapWidth);
    };
  }
}
