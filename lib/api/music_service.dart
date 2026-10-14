import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../services/debug_log.dart';
import '../services/youtube_block.dart';
import '../services/youtube_audio_extractor.dart';
import '../services/youtube_mirror_service.dart';
import '../services/webview_ejs_solver.dart';

class _CachedUrl {
  final String url;
  final DateTime cachedAt;
  _CachedUrl(this.url) : cachedAt = DateTime.now();
  bool get isExpired => DateTime.now().difference(cachedAt).inHours >= 5;
}

class MusicTrack {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String cover;
  final int duration;
  final String? localPath;

  MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.cover,
    required this.duration,
    this.localPath,
  });

  factory MusicTrack.fromJson(Map<String, dynamic> json) {
    final artistObj = json['artist'];
    final albumObj = json['album'];
    
    // Check if this is a raw API response or our saved JSON
    String artistName = 'Unknown Artist';
    if (artistObj is Map) {
      artistName = artistObj['name'] ?? 'Unknown Artist';
    } else if (artistObj is String) {
      artistName = artistObj;
    }

    String albumTitle = '';
    String coverUrl = '';
    if (albumObj is Map) {
      albumTitle = albumObj['title'] ?? '';
      coverUrl = albumObj['cover_xl'] ?? albumObj['cover_big'] ?? albumObj['cover_medium'] ?? albumObj['cover_small'] ?? '';
    } else if (albumObj is String) {
      albumTitle = albumObj;
      coverUrl = json['cover'] ?? '';
    }

    return MusicTrack(
      id: json['id'].toString(),
      title: json['title'] ?? 'Unknown Title',
      artist: artistName,
      album: albumTitle,
      cover: coverUrl.isNotEmpty ? coverUrl : (json['cover'] ?? ''),
      duration: json['duration'] ?? 0,
      localPath: json['localPath'],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'cover': cover,
    'duration': duration,
    'localPath': localPath,
  };
}

class MusicAlbum {
  final String id;
  final String title;
  final String artist;
  final String cover;
  final int? nbTracks;

  MusicAlbum({
    required this.id,
    required this.title,
    required this.artist,
    required this.cover,
    this.nbTracks,
  });

  factory MusicAlbum.fromJson(Map<String, dynamic> json) {
    final artistObj = json['artist'] ?? {};

    return MusicAlbum(
      id: json['id'].toString(),
      title: json['title'] ?? '',
      artist: artistObj['name'] ?? 'Unknown Artist',
      cover: json['cover_xl'] ?? json['cover_big'] ?? json['cover_medium'] ?? json['cover_small'] ?? '',
      nbTracks: json['nb_tracks'],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'cover': cover,
    'nbTracks': nbTracks,
  };
}

class MusicService {
  final _yt = YoutubeExplode();

  // A second YoutubeExplode that can solve YouTube's JS challenges using the
  // device's own JS engine (hidden WebView). This unlocks the Safari/TV
  // clients on phones, where yt-dlp isn't available. Created on first use.
  Future<YoutubeExplode?>? _solverYtFuture;
  DateTime? _solverFailedAt;
  String? _solverError;

  // Why each method failed on the last stream lookup, so the player can show
  // a useful message instead of a generic "didn't work".
  final List<String> _failures = [];
  String? get lastFailureSummary =>
      _failures.isEmpty ? null : _failures.join('\n');

  void _noteFailure(String method, Object reason) {
    var r = reason.toString().split('\n').first.trim();
    r = r.replaceFirst(RegExp(r'^(Exception|YoutubeExplodeException|VideoUnplayableException|ClientException)[:\s]*'), '');
    if (r.length > 90) r = '${r.substring(0, 90)}…';
    _failures.add('• $method: $r');
    DebugLog.write('music', '$method failed: ${reason.toString().replaceAll('\n', ' | ')}');
  }

  Future<YoutubeExplode?> _solverYt() {
    // Windows has yt-dlp; Linux has no headless WebView.
    if (!(Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) {
      return Future.value(null);
    }
    // After a failure, wait a bit before trying to start it again.
    if (_solverFailedAt != null &&
        DateTime.now().difference(_solverFailedAt!) < const Duration(minutes: 5)) {
      return Future.value(null);
    }
    return _solverYtFuture ??= () async {
      try {
        final solver = await WebViewEJSSolver.init();
        debugPrint('MusicService: JS challenge solver ready');
        return YoutubeExplode(jsSolver: solver);
      } catch (e) {
        debugPrint('MusicService: JS challenge solver unavailable: $e');
        _solverError = e.toString();
        _solverFailedAt = DateTime.now();
        _solverYtFuture = null;
        return null;
      }
    }();
  }

  // Caches for fast playback
  final Map<String, String> _videoIdCache = {};
  final Map<String, _CachedUrl> _streamUrlCache = {};

  static const _requestTimeout = Duration(seconds: 8);
  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
  };

  /// GET + decode a Deezer JSON response. Every request has a hard timeout
  /// (previously there was none, so a stalled connection left the Music page
  /// on its loading shimmer forever) and Deezer's in-body error objects
  /// (e.g. quota exceeded, returned with HTTP 200) are surfaced as errors
  /// instead of crashing later on a null cast.
  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final response =
        await http.get(uri, headers: _headers).timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw Exception('Deezer HTTP ${response.statusCode}');
    }
    final decoded = json.decode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected Deezer response shape');
    }
    if (decoded['error'] != null) {
      throw Exception('Deezer error: ${decoded['error']}');
    }
    return decoded;
  }

  /// Generic retry wrapper — retries up to [maxRetries] times with backoff.
  /// If [rethrowOnFailure] is true and every attempt threw, the last error is
  /// rethrown so the UI can show an error state instead of an empty page.
  Future<T> _withRetry<T>(
    Future<T> Function() fn,
    T fallback, {
    int maxRetries = 3,
    bool rethrowOnFailure = false,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final result = await fn();
        lastError = null;
        // For lists, treat empty as "no data" and retry
        if (result is List && result.isEmpty && attempt < maxRetries) {
          debugPrint('MusicService: Attempt $attempt returned empty, retrying...');
          await Future.delayed(Duration(milliseconds: 300 * attempt));
          continue;
        }
        return result;
      } catch (e) {
        lastError = e;
        debugPrint('MusicService: Attempt $attempt failed: $e');
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
    if (rethrowOnFailure && lastError != null) throw lastError;
    return fallback;
  }

  Future<List<MusicTrack>> searchTracks(String query) => _withRetry(() async {
    final data = await _getJson(Uri.https('api.deezer.com', '/search', {'q': query}));
    final items = (data['data'] as List?) ?? const [];
    return items.map((item) => MusicTrack.fromJson(item)).toList();
  }, <MusicTrack>[]);

  Future<List<MusicTrack>> getTrendingTracks({int index = 0, int limit = 20}) => _withRetry(() async {
    final data = await _getJson(Uri.https('api.deezer.com', '/chart/0/tracks', {
      'index': index.toString(),
      'limit': limit.toString(),
    }));
    final items = (data['data'] as List?) ?? const [];
    return items.map((item) => MusicTrack.fromJson(item)).toList();
  }, <MusicTrack>[], rethrowOnFailure: true);

  /// Apple Music's public "Most Played" chart (a free, official, no-key-needed
  /// RSS/JSON feed) used as the homepage trending list. Falls back to the
  /// Deezer chart (getTrendingTracks) if the feed can't be read.
  Future<List<MusicTrack>> getAppleMusicTrending({int limit = 25}) => _withRetry(() async {
    final data = await _getJson(Uri.parse(
        'https://rss.applemarketingtools.com/api/v2/us/music/most-played/$limit/songs.json'));
    final items = (data['feed']?['results'] as List?) ?? const [];
    return items.map((item) {
      final artwork = (item['artworkUrl100'] as String? ?? '')
          .replaceAll('100x100bb.jpg', '400x400bb.jpg');
      return MusicTrack(
        id: 'am_${item['id']}',
        title: (item['name'] ?? 'Unknown Title').toString(),
        artist: (item['artistName'] ?? 'Unknown Artist').toString(),
        album: (item['collectionName'] ?? item['name'] ?? '').toString(),
        cover: artwork,
        duration: 0,
      );
    }).toList();
  }, <MusicTrack>[], rethrowOnFailure: true);

  Future<List<MusicAlbum>> searchAlbums(String query) => _withRetry(() async {
    final data = await _getJson(Uri.https('api.deezer.com', '/search/album', {'q': query}));
    final albums = (data['data'] as List?) ?? const [];
    return albums.map((item) => MusicAlbum.fromJson(item)).toList();
  }, <MusicAlbum>[]);

  Future<List<MusicTrack>> getAlbumTracks(String albumId) => _withRetry(() async {
    final albumData = await _getJson(Uri.https('api.deezer.com', '/album/$albumId'));
    final items = (albumData['tracks']?['data'] as List?) ?? const [];

    return items.map((trackJson) {
       trackJson['album'] = {
         'title': albumData['title'],
         'cover_xl': albumData['cover_xl'],
         'cover_big': albumData['cover_big'],
         'cover_medium': albumData['cover_medium'],
         'cover_small': albumData['cover_small'],
       };
       return MusicTrack.fromJson(trackJson);
    }).toList();
  }, <MusicTrack>[]);

  Future<List<MusicTrack>> getRelatedTracks(String trackId) => _withRetry(() async {
    final data = await _getJson(Uri.https('api.deezer.com', '/track/$trackId/related'));
    final items = data['data'];
    if (items is List) {
      return items.map((item) => MusicTrack.fromJson(item)).toList();
    }
    return <MusicTrack>[];
  }, <MusicTrack>[]);

  Future<String?> getYoutubeVideoId(String title, String artist) async {
    final cacheKey = '$title|$artist';
    if (_videoIdCache.containsKey(cacheKey)) {
      debugPrint('MusicService: Video ID cache hit for "$title"');
      return _videoIdCache[cacheKey];
    }

    if (YoutubeBlock.isBlocked) return null; // don't hammer a blocked connection

    // Warm up the phone-side JS challenge solver while we search, so it's
    // ready by the time the stream URL is needed.
    unawaited(_solverYt());

    // Run the searches side by side; first match wins. The public-mirror
    // search starts a few seconds later, only if the others are slow/blocked.
    var found = false;
    final id = await _firstNonNullUrl([
      _fastSearchVideoId(title, artist),
      _librarySearchVideoId(title, artist),
      Future<String?>.delayed(const Duration(seconds: 3), () async {
        if (found) return null;
        try {
          final mirrorId =
              await YoutubeMirrorService.instance.searchVideoId(title, artist);
          if (mirrorId != null) debugPrint('MusicService: videoId via public mirror search');
          return mirrorId;
        } catch (e) {
          debugPrint('MusicService: Mirror search failed: $e');
          return null;
        }
      }),
    ]);
    found = true;
    if (id != null) _videoIdCache[cacheKey] = id;
    return id;
  }

  // Fast path: YouTube results-page HTML + regex (ported from PlayTorrio TV).
  Future<String?> _fastSearchVideoId(String title, String artist) async {
    try {
      final fastId = await YoutubeAudioExtractor.instance
          .searchVideoId(title, artist);
      if (fastId != null) {
        debugPrint('MusicService: Fast videoId match for "$title"');
      }
      return fastId;
    } catch (e) {
      debugPrint('MusicService: Fast search failed: $e');
      return null;
    }
  }

  // youtube_explode_dart full search.
  Future<String?> _librarySearchVideoId(String title, String artist) async {
    try {
      final searchQuery = '$title - $artist lyrics';
      final searchList = await _yt.search.search(searchQuery);
      if (searchList.isNotEmpty) {
        for (final video in searchList) {
          if (video.duration != null && video.duration!.inSeconds > 60) {
            return video.id.value;
          }
        }
        return searchList.first.id.value;
      }
    } catch (e) {
      debugPrint('MusicService: YouTube matching error: $e');
    }
    return null;
  }

  /// Fast stream URL fetching for playback. Asks yt-dlp for the link AND the
  /// headers it would send with it (User-Agent etc.), because YouTube refuses
  /// the link if the player presents a different identity.
  Future<String?> _ytDlpStreamUrl(String videoId) async {
    if (!Platform.isWindows) return null;
    try {
      final exe = File(
          '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}yt-dlp.exe');
      if (!await exe.exists()) {
        debugPrint('MusicService: yt-dlp.exe not found at ${exe.path}');
        _noteFailure('yt-dlp', 'yt-dlp.exe not found next to the app');
        return null;
      }
      final res = await Process.run(exe.path, [
        '-f', 'bestaudio/best',
        '--no-playlist',
        '--no-warnings',
        '-j',
        'https://www.youtube.com/watch?v=$videoId',
      ]).timeout(const Duration(seconds: 40));
      if (res.exitCode != 0) {
        debugPrint('MusicService: yt-dlp failed: ${res.stderr}');
        final err = res.stderr
            .toString()
            .split('\n')
            .map((l) => l.trim())
            .lastWhere((l) => l.isNotEmpty, orElse: () => 'exit code ${res.exitCode}');
        _noteFailure('yt-dlp', err);
        return null;
      }
      final out = res.stdout.toString().trim();
      final start = out.indexOf('{');
      if (start < 0) {
        _noteFailure('yt-dlp', 'no data returned');
        return null;
      }
      final info = jsonDecode(out.substring(start)) as Map<String, dynamic>;
      final url = info['url']?.toString() ?? '';
      if (!url.startsWith('http')) {
        _noteFailure('yt-dlp', 'no audio link in the result');
        return null;
      }
      final h = info['http_headers'];
      if (h is Map) {
        _headersByUrl[url] = h.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
      return url;
    } catch (e) {
      debugPrint('MusicService: yt-dlp error: $e');
      _noteFailure('yt-dlp', e is TimeoutException ? 'timed out' : e);
      return null;
    }
  }

  // Clients that YouTube still serves without a "proof of origin" token
  // (same identities yt-dlp uses by default as of Oct 2026). The library's
  // own Android/iPhone/VR clients now get their links refused.
  static const _visionOsUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
  static const _tvSamsungUa =
      'Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1';
  static const _visionOsClient = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'VISIONOS',
        'clientVersion': '1.02',
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice17,1',
        'userAgent': _visionOsUa,
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
        'hl': 'en',
        'gl': 'US',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');
  static const _tvSamsungClient = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'TVHTML5',
        'clientVersion': '5.20260707',
        'deviceMake': 'Samsung',
        'deviceModel': 'UKS9800',
        'userAgent': _tvSamsungUa,
        'osName': 'Tizen',
        'osVersion': '2.4.0',
        'hl': 'en',
        'gl': 'US',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  // Which YouTube identity produced a link decides which headers it will
  // accept. Without matching headers the player gets refused ("link blocked").
  static const _androidUa =
      'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
  static const _iosUa =
      'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';
  static const _vrUa =
      'com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1) gzip';
  static const _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  final Map<String, String> _uaByUrl = {};
  // Full header sets reported by yt-dlp for the links it produced.
  final Map<String, Map<String, String>> _headersByUrl = {};

  /// Headers to open [url] with so YouTube treats it like the app that asked.
  Map<String, String> playbackHeaders(String url) {
    final exact = _headersByUrl[url];
    if (exact != null) {
      return {
        for (final e in exact.entries)
          if (e.key.toLowerCase() != 'accept-encoding') e.key: e.value,
      };
    }
    final ua = _uaByUrl[url] ??
        YoutubeAudioExtractor.userAgentForUrl(url) ??
        _browserUa;
    return {'User-Agent': ua, 'Referer': 'https://www.youtube.com/'};
  }

  void forgetStreamUrl(String videoId) => _streamUrlCache.remove(videoId);

  Future<String?> getYoutubeStreamUrl(String videoId, {bool skipFastPath = false}) async {
    final cached = _streamUrlCache[videoId];
    if (!skipFastPath && cached != null && !cached.isExpired) {
      debugPrint('MusicService: Stream URL cache hit');
      return cached.url;
    }

    if (YoutubeBlock.isBlocked) return null; // don't hammer a blocked connection
    if (!skipFastPath) _failures.clear(); // keep first-try reasons on the retry
    // First choice: yt-dlp (shipped next to the exe on Windows). The
    // in-app InnerTube extractor below is already known to get blocked on
    // this network, so trying it first only burns time before falling
    // back — go straight to the one that actually works.
    final dlpUrl = await _ytDlpStreamUrl(videoId);
    if (dlpUrl != null) {
      _streamUrlCache[videoId] = _CachedUrl(dlpUrl);
      debugPrint('MusicService: Got stream URL via yt-dlp');
      return dlpUrl;
    }

    // Everything below runs side by side and the first working URL wins,
    // so a blocked method can't eat the player's whole time budget:
    //  1. the fast InnerTube extractor (ported from PlayTorrio TV),
    //  2. youtube_explode_dart with several YouTube clients (plus the JS
    //     challenge solver on phones),
    //  3. public Invidious/Piped mirrors — started a few seconds later so
    //     they're only used when the direct methods are slow or blocked.
    // On a retry (the first URL didn't play) skip the methods that just
    // produced a dud and go to the mirrors right away.
    var resolved = false;
    final url = await _firstNonNullUrl([
      if (!skipFastPath) _fastExtractorUrl(videoId),
      _libraryStreamUrl(videoId, solverOnly: skipFastPath),
      Future<String?>.delayed(Duration(seconds: skipFastPath ? 0 : 4), () async {
        if (resolved) return null;
        return _mirrorStreamUrl(videoId);
      }),
    ]);
    resolved = true;

    if (url != null) {
      _streamUrlCache[videoId] = _CachedUrl(url);
      return url;
    }
    debugPrint('MusicService: All methods failed for $videoId');
    return null;
  }

  Future<String?> _fastExtractorUrl(String videoId) async {
    try {
      final fastUrl = await YoutubeAudioExtractor.instance.getAudioUrl(videoId);
      if (fastUrl != null) {
        debugPrint('MusicService: Got stream URL via fast extractor');
      } else {
        _noteFailure('Built-in extractor', 'no audio returned');
      }
      return fastUrl;
    } catch (e) {
      debugPrint('MusicService: Fast extractor failed: $e');
      _noteFailure('Built-in extractor', e);
      return null;
    }
  }

  Future<String?> _libraryStreamUrl(String videoId, {bool solverOnly = false}) async {
    // Start the JS challenge solver in the background (first use takes a
    // moment) while trying the clients that don't need it.
    final solverFuture = _solverYt();

    Future<String?> tryClient(YoutubeExplode yt, YoutubeApiClient client, String name, String ua) async {
      try {
        final manifest = await yt.videos.streamsClient
            .getManifest(videoId, ytClients: [client])
            .timeout(const Duration(seconds: 7));
        final audioStreams = manifest.audioOnly.toList();
        if (audioStreams.isEmpty) {
          _noteFailure(name, 'no audio streams');
          return null;
        }
        audioStreams.sort((a, b) => b.bitrate.compareTo(a.bitrate));
        debugPrint('MusicService: Got stream URL via $name');
        final u = audioStreams.first.url.toString();
        _uaByUrl[u] = ua;
        return u;
      } catch (e) {
        debugPrint('MusicService: $name failed: $e');
        _noteFailure(name, e is TimeoutException ? 'timed out' : e);
        return null;
      }
    }

    // Newer client that avoids YouTube's extra proof checks (lib 3.1+),
    // the VR client that worked before, and the iPhone client — all at once.
    if (!solverOnly) {
      final url = await _firstNonNullUrl([
        tryClient(_yt, _visionOsClient, 'visionOS client', _visionOsUa),
        tryClient(_yt, _tvSamsungClient, 'Samsung TV client', _tvSamsungUa),
        tryClient(_yt, YoutubeApiClient.androidSdkless, 'Android client', _androidUa),
        tryClient(_yt, YoutubeApiClient.androidVr, 'VR client', _vrUa),
        tryClient(_yt, YoutubeApiClient.ios, 'iPhone client', _iosUa),
      ]);
      if (url != null) return url;
    }

    // Safari and TV need the JS challenge solver (phones only).
    final solverYt = await solverFuture;
    if (solverYt == null) {
      if (_solverError != null) _noteFailure('Unblocking code', _solverError!);
      return null;
    }
    return _firstNonNullUrl([
      tryClient(solverYt, _tvSamsungClient, 'Samsung TV client (unblocked)', _tvSamsungUa),
      tryClient(solverYt, YoutubeApiClient.safari, 'Safari client', _browserUa),
      tryClient(solverYt, YoutubeApiClient.tv, 'TV client', 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)'),
    ]);
  }

  Future<String?> _mirrorStreamUrl(String videoId) async {
    try {
      final url = await YoutubeMirrorService.instance.audioUrl(videoId);
      if (url != null) {
        debugPrint('MusicService: Got stream URL via public mirror');
      } else {
        _noteFailure('Public mirrors', 'no server could play it');
      }
      return url;
    } catch (e) {
      debugPrint('MusicService: Mirror lookup failed: $e');
      _noteFailure('Public mirrors', e);
      return null;
    }
  }

  /// Completes with the first non-null URL, or null once all have finished.
  static Future<String?> _firstNonNullUrl(List<Future<String?>> futures) {
    if (futures.isEmpty) return Future.value(null);
    final completer = Completer<String?>();
    var remaining = futures.length;
    for (final f in futures) {
      f.then((value) {
        if (value != null && value.isNotEmpty && !completer.isCompleted) {
          completer.complete(value);
        }
      }, onError: (_) {}).whenComplete(() {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) completer.complete(null);
      });
    }
    return completer.future;
  }

  Future<StreamManifest?> getYoutubeManifest(String videoId) async {
    final clientSets = [
      [YoutubeApiClient.androidVr],
      [YoutubeApiClient.tv],
    ];

    for (final clients in clientSets) {
      try {
        return await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: clients,
        );
      } catch (e) {
        debugPrint('MusicService: ${clients.first} manifest failed: $e');
      }
    }
    return null;
  }

  YoutubeExplode get yt => _yt;

  void dispose() {
    _yt.close();
  }
}
