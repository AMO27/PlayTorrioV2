import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'music_service.dart';

class LyricLine {
  final Duration startTime;
  final String text;

  LyricLine({required this.startTime, required this.text});

  Map<String, dynamic> toJson() => {
    'startTimeMs': startTime.inMilliseconds,
    'text': text,
  };

  factory LyricLine.fromJson(Map<String, dynamic> json) => LyricLine(
    startTime: Duration(milliseconds: json['startTimeMs']),
    text: json['text'],
  );
}

class LyricsService {
  Future<List<LyricLine>?> getSyncedLyrics({
    required String trackName,
    required String artistName,
    required String albumName,
    required int durationSeconds,
  }) async {
    // Exact match first (requires track/artist/album/duration to all line
    // up, which lrclib.net is strict about).
    try {
      final uri = Uri.https('lrclib.net', '/api/get', {
        'track_name': trackName,
        'artist_name': artistName,
        'album_name': albumName,
        'duration': durationSeconds.toString(),
      });

      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final String? syncedLyrics = data['syncedLyrics'];
        if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
          debugPrint('LyricsService: Received synced lyrics (${syncedLyrics.length} chars)');
          return _parseLrc(syncedLyrics);
        }
      }
    } catch (e) {
      debugPrint('LyricsService: Error fetching lyrics: $e');
    }

    // Fallback: fuzzy search. The exact-match endpoint above 404s the
    // moment the album title or duration doesn't line up exactly with
    // lrclib's records (e.g. Deezer's album name has "(Deluxe Edition)"
    // and lrclib's doesn't), which was making a lot of real matches show
    // up as "No lyrics available" even though lrclib actually has them.
    try {
      final searchUri = Uri.https('lrclib.net', '/api/search', {
        'track_name': trackName,
        'artist_name': artistName,
      });
      final response = await http.get(searchUri);
      if (response.statusCode == 200) {
        final List results = json.decode(response.body);
        if (results.isNotEmpty) {
          // Prefer a result whose duration is close to ours, then fall
          // back to the first result that has synced lyrics at all.
          Map<String, dynamic>? best;
          int bestDiff = 1 << 30;
          for (final r in results) {
            if (r is! Map) continue;
            final synced = r['syncedLyrics'];
            if (synced == null || (synced is String && synced.isEmpty)) continue;
            final dur = r['duration'];
            final diff = dur is num ? (dur.toInt() - durationSeconds).abs() : 1 << 29;
            if (diff < bestDiff) {
              bestDiff = diff;
              best = r.cast<String, dynamic>();
            }
          }
          final String? syncedLyrics = best?['syncedLyrics'];
          if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
            debugPrint('LyricsService: Received synced lyrics via search fallback (${syncedLyrics.length} chars)');
            return _parseLrc(syncedLyrics);
          }
        }
      }
    } catch (e) {
      debugPrint('LyricsService: Error searching lyrics: $e');
    }
    return null;
  }

  List<LyricLine> _parseLrc(String lrcContent) {
    final List<LyricLine> lines = [];
    final RegExp regExp = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\](.*)');

    for (var line in lrcContent.split('\n')) {
      final match = regExp.firstMatch(line.trim());
      if (match != null) {
        try {
          final int minutes = int.parse(match.group(1)!);
          final double seconds = double.parse(match.group(2)!);
          final String text = match.group(3)!.trim();

          if (text.isNotEmpty) {
            final duration = Duration(
              minutes: minutes,
              seconds: seconds.toInt(),
              milliseconds: ((seconds % 1) * 1000).toInt(),
            );
            lines.add(LyricLine(startTime: duration, text: text));
          }
        } catch (e) {
          // Skip malformed lines
        }
      }
    }
    debugPrint('LyricsService: Parsed ${lines.length} lines');
    return lines;
  }

  Future<void> saveLyrics(MusicTrack track, List<LyricLine> lyrics) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final lyricsDir = Directory('${dir.path}/lyrics');
      if (!await lyricsDir.exists()) await lyricsDir.create(recursive: true);

      final file = File('${lyricsDir.path}/${track.id}.json');
      final data = lyrics.map((l) => l.toJson()).toList();
      await file.writeAsString(json.encode(data));
    } catch (e) {
      debugPrint('LyricsService: Error saving local lyrics: $e');
    }
  }

  Future<List<LyricLine>?> getLocalLyrics(MusicTrack track) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/lyrics/${track.id}.json');
      if (await file.exists()) {
        final String content = await file.readAsString();
        final List data = json.decode(content);
        return data.map((item) => LyricLine.fromJson(item)).toList();
      }
    } catch (e) {
      debugPrint('LyricsService: Error reading local lyrics: $e');
    }
    return null;
  }
}
