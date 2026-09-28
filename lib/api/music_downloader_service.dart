import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'music_service.dart';
import 'music_storage_service.dart';
import 'lyrics_service.dart';

/// Emitted whenever a queued download finishes, successfully or not, so UI
/// screens can surface a snackbar even though the actual work happens later,
/// asynchronously, after the "added to queue" response.
class DownloadResultEvent {
  final MusicTrack track;
  final bool success;
  final String? error;

  const DownloadResultEvent({required this.track, required this.success, this.error});
}

class MusicDownloaderService {
  static final MusicDownloaderService _instance = MusicDownloaderService._internal();
  factory MusicDownloaderService() => _instance;
  MusicDownloaderService._internal();

  final MusicService _musicService = MusicService();
  final LyricsService _lyricsService = LyricsService();
  final MusicStorageService _storageService = MusicStorageService();

  // Queue Management
  final Queue<MusicTrack> _queue = Queue<MusicTrack>();
  final Set<String> _activeDownloadIds = {};
  bool _isProcessing = false;

  final StreamController<DownloadResultEvent> _resultsController =
      StreamController<DownloadResultEvent>.broadcast();

  /// Subscribe to get notified when a download finishes or fails, e.g. to
  /// show a snackbar. The initial "queued" response from [downloadTrack]
  /// only tells you it was accepted, not whether it ultimately succeeded.
  Stream<DownloadResultEvent> get onResult => _resultsController.stream;

  Future<bool> downloadTrack(MusicTrack track) async {
    // 1. Check if already downloaded
    final downloadedTracks = await _storageService.getDownloadedTracks();
    if (downloadedTracks.any((t) => t.id == track.id)) {
      debugPrint('[Downloader] Song already downloaded: ${track.title}');
      return true; // Consider success if already there
    }

    // 2. Check if already in active download or queue
    if (_activeDownloadIds.contains(track.id)) {
      debugPrint('[Downloader] Song is already downloading or queued: ${track.title}');
      return false;
    }

    // 3. Add to Queue
    _activeDownloadIds.add(track.id);
    _queue.add(track);
    debugPrint('[Downloader] Added to queue: ${track.title}. Queue size: ${_queue.length}');

    // 4. Start processing if not already
    if (!_isProcessing) {
      _processQueue();
    }

    return true; // Request accepted
  }

  Future<void> _processQueue() async {
    if (_queue.isEmpty) {
      _isProcessing = false;
      return;
    }

    _isProcessing = true;
    final track = _queue.removeFirst();

    try {
      await _executeDownload(track);
      _resultsController.add(DownloadResultEvent(track: track, success: true));
    } catch (e) {
      debugPrint('[Downloader] Error processing ${track.title}: $e');
      _resultsController.add(DownloadResultEvent(track: track, success: false, error: e.toString()));
    } finally {
      _activeDownloadIds.remove(track.id);
      _processQueue(); // Process next in queue
    }
  }

  Future<void> _executeDownload(MusicTrack track) async {
    try {
      debugPrint('[Downloader] Starting download for: ${track.title}');
      
      // 1. Request Basic Permissions
      if (Platform.isAndroid) {
        await _requestPermissions();
      }

      // 2. Get the video ID
      final videoId = await _musicService.getYoutubeVideoId(track.title, track.artist);
      if (videoId == null) throw Exception('No YouTube match found');

      // 3. Resolve a playable stream URL using the same fast-extractor ->
      // yt-dlp -> youtube_explode_dart fallback chain already used for
      // playback (getYoutubeManifest has no fallback and is what YouTube
      // was blocking, which is why downloads were silently failing).
      final streamUrl = await _musicService.getYoutubeStreamUrl(videoId);
      if (streamUrl == null) throw Exception('Failed to resolve a stream URL');

      // 4. Prepare Directory
      Directory? dir;
      if (Platform.isAndroid) {
        final externalDirs = await getExternalStorageDirectories(type: StorageDirectory.music);
        if (externalDirs != null && externalDirs.isNotEmpty) {
          dir = externalDirs.first;
        } else {
          final appDir = await getExternalStorageDirectory();
          dir = Directory('${appDir!.path}/Music');
        }
      } else {
        final downloads = await getDownloadsDirectory();
        dir = Directory('${downloads!.path}/PlayTorrio Music');
      }

      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final cleanName = "${track.title} - ${track.artist}".replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
      final file = File('${dir.path}/$cleanName.mp3');
      
      // 5. Download Stream. googlevideo URLs are sometimes rejected without
      // a browser-like User-Agent/Referer (the raw Dart http client's
      // default headers can get a 403 where mpv/yt-dlp's own requests
      // succeed), so send headers that mirror a normal browser fetch.
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(streamUrl))
          ..headers.addAll({
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            'Referer': 'https://www.youtube.com/',
          });
        final httpResponse = await client.send(request);
        if (httpResponse.statusCode != 200 && httpResponse.statusCode != 206) {
          throw Exception('Stream request failed with status ${httpResponse.statusCode}');
        }
        final fileStream = file.openWrite();
        await httpResponse.stream.pipe(fileStream);
        await fileStream.flush();
        await fileStream.close();
      } finally {
        client.close();
      }

      // 6. Download Cover Art
      String localCoverPath = track.cover;
      try {
        final coverRes = await http.get(Uri.parse(track.cover));
        if (coverRes.statusCode == 200) {
          final coverFile = File('${dir.path}/$cleanName.jpg');
          await coverFile.writeAsBytes(coverRes.bodyBytes);
          localCoverPath = coverFile.path;
        }
      } catch (e) {
        debugPrint('[Downloader] Failed to save local cover art: $e');
      }

      // 7. Download and Save Lyrics
      try {
        final lyrics = await _lyricsService.getSyncedLyrics(
          trackName: track.title,
          artistName: track.artist,
          albumName: track.album,
          durationSeconds: track.duration,
        );
        if (lyrics != null) {
          await _lyricsService.saveLyrics(track, lyrics);
          debugPrint('[Downloader] Saved lyrics offline for: ${track.title}');
        }
      } catch (e) {
        debugPrint('[Downloader] Failed to save lyrics: $e');
      }

      // 8. Save to Local Storage
      final downloadedTrack = MusicTrack(
        id: track.id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        cover: localCoverPath,
        duration: track.duration,
        localPath: file.path,
      );
      await _storageService.saveDownloadedTrack(downloadedTrack);

      debugPrint('[Downloader] Success: ${track.title}');
    } catch (e) {
      debugPrint('[Downloader] Error in _executeDownload: $e');
      rethrow;
    }
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await Permission.audio.request();
      await Permission.storage.request();
    }
  }
}
