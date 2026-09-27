import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'music_service.dart';
import 'music_storage_service.dart';
import 'audio_handler.dart';
import 'lyrics_service.dart';

class MusicPlayerService {
  static final MusicPlayerService _instance = MusicPlayerService._internal();
  factory MusicPlayerService() => _instance;
  MusicPlayerService._internal();

  final Player _player = Player();
  final MusicService _musicService = MusicService();
  final MusicStorageService _storageService = MusicStorageService();
  PlayTorrioAudioHandler? _handler;
  final LyricsService _lyricsService = LyricsService();

  Player get player => _player;

  void setHandler(BaseAudioHandler handler) {
    _handler = handler as PlayTorrioAudioHandler;
  }

  final ValueNotifier<MusicTrack?> currentTrack = ValueNotifier<MusicTrack?>(null);
  final ValueNotifier<List<MusicTrack>> playlist = ValueNotifier<List<MusicTrack>>([]);
  final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<bool> isBuffering = ValueNotifier<bool>(false);
  /// Non-null when the last play attempt failed; the UI shows it once.
  final ValueNotifier<String?> playbackError = ValueNotifier<String?>(null);
  final ValueNotifier<bool> isShuffleEnabled = ValueNotifier<bool>(false);
  final ValueNotifier<PlaylistMode> loopMode = ValueNotifier<PlaylistMode>(PlaylistMode.none);
  final ValueNotifier<bool> isFullScreenVisible = ValueNotifier<bool>(false);
  final ValueNotifier<List<LyricLine>?> lyrics = ValueNotifier<List<LyricLine>?>(null);
  final ValueNotifier<Widget?> bottomWidget = ValueNotifier<Widget?>(null);

  int _currentIndex = -1;
  bool _initialized = false;
  // ignore: unused_field
  bool _isManuallyPaused = false;
  bool _isLoadingTrack = false;
  int _playGeneration = 0; // Cancellation token for YT extraction
  final Set<String> _shufflePlayedIds = {};
  final Random _random = Random();

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    
    // Configure audio session. Best-effort: audio_session has no native
    // implementation on every desktop platform, and if this threw, init()
    // aborted here and the player listeners below were never attached (so the
    // UI never learned the player state).
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      // Listen for interruptions (Phone calls, other apps starting media)
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              pause();
              break;
          }
        }
      });

      // Listen for "becoming noisy" (Headphones unplugged)
      session.becomingNoisyEventStream.listen((_) => pause());
    } catch (e) {
      debugPrint('MusicPlayerService: audio session unavailable (continuing): $e');
    }

    // Initialize storage notifiers
    await _storageService.init();

    // Listen to player state streams
    _player.stream.playing.listen((p) {
      debugPrint('MusicPlayerService: playing state changed -> $p');
      isPlaying.value = p;
      // Request audio focus when starting to play
      if (p) {
        AudioSession.instance.then((s) => s.setActive(true));
      }
    });
    _player.stream.buffering.listen((b) {
      debugPrint('MusicPlayerService: buffering -> $b');
      isBuffering.value = b;
    });
    _player.stream.position.listen((p) => position.value = p);
    _player.stream.duration.listen((d) {
      if (d != Duration.zero) {
        debugPrint('MusicPlayerService: duration loaded -> $d');
      }
      duration.value = d;
    });
    _player.stream.playlistMode.listen((m) => loopMode.value = m);

    _player.stream.error.listen((e) {
      debugPrint('MusicPlayerService: PLAYER ERROR -> $e');
    });
    _player.stream.log.listen((l) {
      // mpv-level logs (warn/error only to keep noise down).
      // NOTE: media_kit's libmpv log callback is shared globally across all
      // Player instances in the process — meaning logs from the IPTV player
      // (or any other Player) also reach this listener. Only print when this
      // service has an active track loaded so we don't take blame for
      // unrelated mpv chatter.
      if (currentTrack.value == null) return;
      if (l.level == 'error' || l.level == 'warn' || l.level == 'fatal') {
        debugPrint('MusicPlayerService: mpv [${l.level}] ${l.prefix}: ${l.text}');
      }
    });

    _player.stream.completed.listen((completed) {
      debugPrint('MusicPlayerService: completed -> $completed');
      if (completed && !_isLoadingTrack) {
        next();
      }
    });
  }

  Future<void> playTrack(MusicTrack track, {List<MusicTrack>? newPlaylist}) async {
    debugPrint('MusicPlayerService: Preparing to play: ${track.title} by ${track.artist}');
    
    _isLoadingTrack = true;
    final generation = ++_playGeneration; // Cancel any in-flight extraction
    try {
      // 0. Set session active immediately
      try {
        final session = await AudioSession.instance;
        final sessionOk = await session.setActive(true);
        debugPrint('MusicPlayerService: audio session active=$sessionOk');
      } catch (e) {
        debugPrint('MusicPlayerService: audio session unavailable (continuing): $e');
      }
      playbackError.value = null;

      debugPrint('MusicPlayerService: stopping previous playback');
      await _player.stop();

      if (newPlaylist != null) {
        playlist.value = newPlaylist;
        _currentIndex = newPlaylist.indexWhere((t) => t.id == track.id);
        // Reset shuffle tracking for new playlist
        _shufflePlayedIds.clear();
      }

      // Mark this track as played for shuffle
      if (isShuffleEnabled.value) {
        _shufflePlayedIds.add(track.id);
      }

      currentTrack.value = track;
      position.value = Duration.zero;
      duration.value = Duration.zero;
      _isManuallyPaused = false;
      lyrics.value = null;

      // Update notification metadata
      _handler?.updateMediaItem(MediaItem(
        id: track.id,
        album: track.album,
        title: track.title,
        artist: track.artist,
        displayTitle: track.title,
        displaySubtitle: track.artist,
        duration: Duration(seconds: track.duration),
        artUri: track.cover.startsWith('http') 
            ? Uri.tryParse(track.cover) 
            : Uri.file(track.cover),
      ));

      _fetchLyricsForTrack(track);

      // 1. Local Offline Playback
      if (track.localPath != null) {
        final file = File(track.localPath!);
        if (await file.exists()) {
          debugPrint('MusicPlayerService: Playing from local storage: ${track.localPath}');
          try {
            await _player.open(Media(track.localPath!));
            debugPrint('MusicPlayerService: open() returned for local file');
          } catch (e, st) {
            debugPrint('MusicPlayerService: open() THREW for local file: $e\n$st');
            rethrow;
          }
          _prefetchNext();
          return;
        } else {
          debugPrint('MusicPlayerService: localPath set but file missing: ${track.localPath}');
        }
      }

      // 2. YouTube Match (time-limited so the UI can never wait forever)
      debugPrint('MusicPlayerService: resolving videoId for "${track.title}" / "${track.artist}"');
      final videoId = await _musicService
          .getYoutubeVideoId(track.title, track.artist)
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      if (_playGeneration != generation) {
        debugPrint('MusicPlayerService: Cancelled (after videoId) — newer track requested');
        return;
      }
      if (videoId == null) {
        _failPlayback(generation, "Couldn't find this song on YouTube. Try another song or check your connection.");
        return;
      }
      debugPrint('MusicPlayerService: videoId=$videoId');

      // 3. Stream URL, then VERIFY it really plays. A URL that mpv can't fetch
      // leaves the player "buffering" forever, so if no audio starts we retry
      // once with the fallback extractor, then report a clear error.
      for (var attempt = 0; attempt < 2; attempt++) {
        final streamUrl = await _musicService
            .getYoutubeStreamUrl(videoId, skipFastPath: attempt > 0)
            .timeout(const Duration(seconds: 25), onTimeout: () => null);
        if (_playGeneration != generation) {
          debugPrint('MusicPlayerService: Cancelled (after streamUrl) — newer track requested');
          return;
        }
        if (streamUrl == null || streamUrl.isEmpty) {
          debugPrint('MusicPlayerService: no stream URL on attempt ${attempt + 1}');
          continue;
        }
        final preview = streamUrl.length > 120 ? '${streamUrl.substring(0, 120)}…' : streamUrl;
        debugPrint('MusicPlayerService: streamUrl=$preview');

        final started = await _openAndVerify(streamUrl, generation);
        if (_playGeneration != generation) return;
        if (started) {
          _prefetchNext();
          return;
        }
        debugPrint('MusicPlayerService: playback did not start on attempt ${attempt + 1}');
        _musicService.forgetStreamUrl(videoId);
      }
      _failPlayback(generation,
          "Couldn't start playback — YouTube didn't return a stream that plays. Try another song, or try again later.");

    } catch (e, st) {
      debugPrint('MusicPlayerService: Error playing track: $e\n$st');
      _failPlayback(generation, 'Playback error: $e');
    } finally {
      Future.delayed(const Duration(milliseconds: 1500), () {
        _isLoadingTrack = false;
      });
    }
  }

  /// Opens [url] and waits (up to 20 s) for audio to actually start.
  Future<bool> _openAndVerify(String url, int generation) async {
    try {
      await _player.open(Media(url)).timeout(const Duration(seconds: 20));
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        if (_playGeneration != generation) return false;
        if (_player.state.position > Duration.zero) return true;
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } catch (e) {
      debugPrint('MusicPlayerService: open/verify failed: $e');
    }
    return false;
  }

  /// Stops the spinner and tells the UI why playback failed.
  void _failPlayback(int generation, String message) {
    if (_playGeneration != generation) return; // a newer track took over
    debugPrint('MusicPlayerService: FAILED — $message');
    playbackError.value = message;
    isBuffering.value = false;
    _player.stop().catchError((_) {});
  }

  void _fetchLyricsForTrack(MusicTrack track) async {
    try {
      final localLyrics = await _lyricsService.getLocalLyrics(track);
      if (localLyrics != null) {
        lyrics.value = localLyrics;
        return;
      }

      final onlineLyrics = await _lyricsService.getSyncedLyrics(
        trackName: track.title,
        artistName: track.artist,
        albumName: track.album,
        durationSeconds: track.duration,
      );
      
      if (onlineLyrics != null) {
        lyrics.value = onlineLyrics;
        // Cache to disk so a repeat play (or a later offline play) doesn't
        // need to hit lrclib.net again — previously only downloaded tracks
        // got this.
        unawaited(_lyricsService.saveLyrics(track, onlineLyrics));
      } else {
        lyrics.value = []; // Explicitly mark as not found
      }
    } catch (e) {
      debugPrint('MusicPlayerService: Error fetching lyrics: $e');
      lyrics.value = []; // Mark as not found on error too
    }
  }

  void _prefetchNext() async {
    if (playlist.value.isEmpty || _currentIndex == -1) return;
    final nextIndex = (_currentIndex + 1) % playlist.value.length;
    final nextTrack = playlist.value[nextIndex];
    // Prefetch both video ID and stream URL so next track plays instantly
    final videoId = await _musicService.getYoutubeVideoId(nextTrack.title, nextTrack.artist);
    if (videoId != null) {
      await _musicService.getYoutubeStreamUrl(videoId);
    }
  }

  void play() => _player.play();
  void pause() => _player.pause();
  void togglePlay() => _player.playOrPause();

  Future<void> stop() async {
    await _player.stop();
    currentTrack.value = null;
    playlist.value = [];
    _currentIndex = -1;
    isPlaying.value = false;
    _handler?.stop();
  }

  void toggleShuffle() async {
    isShuffleEnabled.value = !isShuffleEnabled.value;
    _shufflePlayedIds.clear();
    // Mark current song as played so it won't be picked next
    if (isShuffleEnabled.value && currentTrack.value != null) {
      _shufflePlayedIds.add(currentTrack.value!.id);
    }
  }

  void toggleLoop() async {
    final modes = [PlaylistMode.none, PlaylistMode.loop, PlaylistMode.single];
    final nextIndex = (modes.indexOf(_player.state.playlistMode) + 1) % modes.length;
    await _player.setPlaylistMode(modes[nextIndex]);
  }

  void seek(Duration pos) => _player.seek(pos);

  void next() {
    if (playlist.value.isEmpty) return;

    if (isShuffleEnabled.value) {
      // Build list of unplayed indices, excluding the current track
      final unplayed = <int>[];
      for (int i = 0; i < playlist.value.length; i++) {
        if (!_shufflePlayedIds.contains(playlist.value[i].id)) {
          unplayed.add(i);
        }
      }

      if (unplayed.isEmpty) {
        // All songs have been played — stop playback
        pause();
        return;
      }

      final nextIndex = unplayed[_random.nextInt(unplayed.length)];
      _currentIndex = nextIndex;
      _shufflePlayedIds.add(playlist.value[nextIndex].id);
      playTrack(playlist.value[nextIndex]);
    } else {
      _currentIndex = (_currentIndex + 1) % playlist.value.length;
      playTrack(playlist.value[_currentIndex]);
    }
  }

  void previous() {
    if (playlist.value.isEmpty) return;
    _currentIndex = (_currentIndex - 1) % playlist.value.length;
    if (_currentIndex < 0) _currentIndex = playlist.value.length - 1;
    playTrack(playlist.value[_currentIndex]);
  }

  bool _disposed = false;

  void dispose() {
    unawaited(disposePlayer());
  }

  /// Stops playback and releases the native mpv instance. Called on app
  /// close — before this existed the music player was never disposed, so its
  /// native threads were still running while the process tried to exit.
  Future<void> disposePlayer() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _player.dispose();
    } catch (_) {}
    try {
      _musicService.dispose();
    } catch (_) {}
  }
}
