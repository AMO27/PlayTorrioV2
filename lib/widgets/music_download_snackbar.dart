import 'package:flutter/material.dart';

import '../api/music_downloader_service.dart';
import '../utils/app_theme.dart';

// Snackbars for music downloads: a live one while a song downloads (stage,
// progress bar, size, time left) and a short one when it finishes. Both use
// the current theme's accent color. Text is white, except on themes with a
// light accent (grey, amber, green, cyan) where it switches to dark text so
// it stays readable. Royal Purple always uses bold white text.

/// Foreground colors that stay readable on [bg].
class _Ink {
  final Color main;
  final Color dim;
  final Color track; // progress bar background
  final FontWeight titleWeight;
  final FontWeight bodyWeight;
  const _Ink(this.main, this.dim, this.track,
      {this.titleWeight = FontWeight.w600, this.bodyWeight = FontWeight.normal});

  factory _Ink.on(Color bg) {
    // Royal Purple: bold white reads best on its lavender accent.
    if (AppTheme.current.name == 'Royal Purple' &&
        bg == AppTheme.current.primaryColor) {
      return const _Ink(Colors.white, Colors.white, Color(0x3DFFFFFF),
          titleWeight: FontWeight.w800, bodyWeight: FontWeight.w700);
    }
    final light = ThemeData.estimateBrightnessForColor(bg) == Brightness.light;
    return light
        ? const _Ink(Color(0xFF111111), Color(0xCC111111), Color(0x33000000))
        : const _Ink(Colors.white, Color(0xDDFFFFFF), Color(0x3DFFFFFF));
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _eta(Duration d) {
  final s = d.inSeconds;
  if (s < 1) return 'almost done';
  if (s < 60) return '${s}s left';
  final m = d.inMinutes;
  final rs = s % 60;
  return rs == 0 ? '${m}m left' : '${m}m ${rs}s left';
}

ShapeBorder get _shape =>
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

/// Shows the live progress snackbar. It stays up until a download finishes,
/// at which point [showMusicDownloadResult] replaces it.
void showMusicDownloadProgress(ScaffoldMessengerState messenger) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(_progressBar());
}

SnackBar _progressBar() {
  final downloader = MusicDownloaderService();
  final bg = AppTheme.current.primaryColor;
  final ink = _Ink.on(bg);
  return SnackBar(
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
      shape: _shape,
      // Replaced by the result snackbar when the song finishes.
      duration: const Duration(hours: 1),
      action: SnackBarAction(
        label: 'Hide',
        textColor: ink.main,
        onPressed: () {},
      ),
      content: ValueListenableBuilder<MusicDownloadProgress?>(
        valueListenable: downloader.progress,
        builder: (context, p, _) {
          if (p == null) {
            return Row(children: [
              SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: ink.main),
              ),
              const SizedBox(width: 12),
              Text('Starting download…',
                  style: TextStyle(color: ink.main, fontWeight: ink.bodyWeight)),
            ]);
          }

          final fraction = p.fraction;
          final details = <String>[];
          if (p.stage == 'Downloading') {
            if (fraction != null) details.add('${(fraction * 100).round()}%');
            if (p.totalBytes != null) {
              details.add('${_mb(p.receivedBytes)} of ${_mb(p.totalBytes!)}');
            } else if (p.receivedBytes > 0) {
              details.add(_mb(p.receivedBytes));
            }
            final left = p.timeLeft;
            if (left != null) details.add(_eta(left));
          } else if (p.stage == 'Finding song') {
            details.add('looking up the audio');
          } else if (p.stage == 'Saving') {
            details.add('adding cover art & lyrics');
          }
          if (p.queuedAfter > 0) {
            details.add('${p.queuedAfter} more in queue');
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.download_rounded, color: ink.main, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${p.stage}: ${p.track.title} — ${p.track.artist}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: ink.main, fontWeight: ink.titleWeight),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  // Indeterminate while looking the song up or when the
                  // size is unknown.
                  value: p.stage == 'Downloading' ? fraction : (p.stage == 'Saving' ? 1.0 : null),
                  minHeight: 5,
                  color: ink.main,
                  backgroundColor: ink.track,
                ),
              ),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(details.join('  •  '),
                    style: TextStyle(color: ink.dim, fontSize: 12, fontWeight: ink.bodyWeight)),
              ],
            ],
          );
        },
      ),
    );
}

/// Replaces the progress snackbar with a done/failed message. If more songs
/// are still queued, the progress snackbar comes back after it.
void showMusicDownloadResult(ScaffoldMessengerState messenger, DownloadResultEvent event) {
  final message = event.success
      ? 'Downloaded: ${event.track.title} — ${event.track.artist}'
      : 'Download failed: ${event.track.title}${event.error != null ? ' — ${event.error}' : ''}';
  final bg = event.success ? AppTheme.current.primaryColor : Colors.red.shade800;
  final ink = _Ink.on(bg);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
      shape: _shape,
      duration: Duration(seconds: event.success ? 4 : 8),
      content: Row(children: [
        Icon(event.success ? Icons.check_circle_rounded : Icons.error_rounded,
            color: ink.main, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: ink.main, fontWeight: ink.titleWeight)),
        ),
      ]),
    ));
  if (MusicDownloaderService().hasPending) {
    // showSnackBar queues behind the result message, so progress for the
    // next song appears once that closes.
    messenger.showSnackBar(_progressBar());
  }
}

/// Shows "already downloaded / already in queue" style info in the same style.
void showMusicDownloadInfo(ScaffoldMessengerState messenger, String text) {
  final bg = AppTheme.current.primaryColor;
  final ink = _Ink.on(bg);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
      shape: _shape,
      duration: const Duration(seconds: 3),
      content: Text(text, style: TextStyle(color: ink.main, fontWeight: ink.titleWeight)),
    ));
}

