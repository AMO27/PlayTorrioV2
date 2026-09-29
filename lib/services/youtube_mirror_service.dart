import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Last-resort YouTube access through public Invidious / Piped servers.
///
/// These community-run mirrors fetch the audio from YouTube on their side and
/// relay it, so YouTube's blocks on this device don't matter. Individual
/// servers come and go (YouTube blocks busy ones), so the list is pulled from
/// the public directories at runtime, several servers are tried at once, and
/// the one that last worked is tried first next time.
class YoutubeMirrorService {
  YoutubeMirrorService._();
  static final YoutubeMirrorService instance = YoutubeMirrorService._();

  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

  // Used when the public directories can't be reached. May be stale; the
  // live directory lists are preferred.
  static const _fallbackInvidious = [
    'https://inv.nadeko.net',
    'https://yewtu.be',
    'https://invidious.nerdvpn.de',
    'https://invidious.f5.si',
  ];
  static const _fallbackPiped = [
    'https://pipedapi.kavin.rocks',
    'https://api.piped.private.coffee',
  ];

  List<_Mirror> _mirrors = const [];
  DateTime? _loadedAt;
  Future<void>? _loading;
  _Mirror? _lastGood;

  // ── Public API ────────────────────────────────────────────────────────────

  /// A playable audio URL for [videoId], or null if no mirror could serve it.
  Future<String?> audioUrl(String videoId) async {
    return _tryMirrors((m) => m.isPiped
        ? _pipedAudio(m.base, videoId)
        : _invidiousAudio(m.base, videoId));
  }

  /// Finds a YouTube video id for a song via Invidious search.
  Future<String?> searchVideoId(String title, String artist) async {
    final query = Uri.encodeQueryComponent('$title $artist');
    return _tryMirrors((m) async {
      if (m.isPiped) return null; // Invidious search is the simpler API
      final res = await _get('${m.base}/api/v1/search?q=$query&type=video');
      if (res == null) return null;
      final data = jsonDecode(res);
      if (data is! List) return null;
      String? first;
      for (final item in data) {
        if (item is! Map) continue;
        final id = item['videoId'];
        if (id is! String || id.isEmpty) continue;
        first ??= id;
        final len = item['lengthSeconds'];
        // Skip shorts/clips: prefer something song-length.
        if (len is num && len > 60) return id;
      }
      return first;
    }, invidiousOnly: true);
  }

  // ── Mirror selection ──────────────────────────────────────────────────────

  Future<String?> _tryMirrors(Future<String?> Function(_Mirror) attempt,
      {bool invidiousOnly = false}) async {
    await _ensureMirrors();
    var candidates = [
      if (_lastGood != null) _lastGood!,
      ..._mirrors.where((m) => m != _lastGood),
    ];
    if (invidiousOnly) {
      candidates = candidates.where((m) => !m.isPiped).toList();
    }
    if (candidates.length > 12) candidates = candidates.sublist(0, 12);

    // Try a few servers at a time; the first one that works wins.
    const batchSize = 4;
    for (var i = 0; i < candidates.length; i += batchSize) {
      final batch = candidates.skip(i).take(batchSize).toList();
      final result = await _firstNonNull(batch.map((m) async {
        try {
          final r = await attempt(m);
          if (r != null) _lastGood = m;
          return r;
        } catch (e) {
          debugPrint('YoutubeMirror: ${m.base} failed: $e');
          return null;
        }
      }).toList());
      if (result != null) return result;
    }
    return null;
  }

  Future<void> _ensureMirrors() {
    final fresh = _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < const Duration(hours: 1) &&
        _mirrors.isNotEmpty;
    if (fresh) return Future.value();
    return _loading ??= _loadMirrors().whenComplete(() => _loading = null);
  }

  Future<void> _loadMirrors() async {
    final results = await Future.wait([
      _loadInvidiousDirectory(),
      _loadPipedDirectory(),
    ]);
    final inv = results[0].isNotEmpty ? results[0] : _fallbackInvidious;
    final piped = results[1].isNotEmpty ? results[1] : _fallbackPiped;

    // Interleave so each batch mixes both kinds of server.
    final mirrors = <_Mirror>[];
    for (var i = 0; i < inv.length || i < piped.length; i++) {
      if (i < inv.length) mirrors.add(_Mirror(inv[i], isPiped: false));
      if (i < piped.length) mirrors.add(_Mirror(piped[i], isPiped: true));
    }
    _mirrors = mirrors;
    _loadedAt = DateTime.now();
    debugPrint('YoutubeMirror: ${inv.length} Invidious + ${piped.length} Piped servers');
  }

  Future<List<String>> _loadInvidiousDirectory() async {
    try {
      final res = await _get('https://api.invidious.io/instances.json?sort_by=health');
      if (res == null) return const [];
      final data = jsonDecode(res);
      if (data is! List) return const [];
      final out = <String>[];
      for (final entry in data) {
        if (entry is! List || entry.length < 2 || entry[1] is! Map) continue;
        final info = entry[1] as Map;
        if (info['type'] != 'https' || info['api'] != true) continue;
        final uri = info['uri'];
        if (uri is String && uri.startsWith('https://')) {
          out.add(uri.replaceAll(RegExp(r'/+$'), ''));
        }
      }
      return out;
    } catch (e) {
      debugPrint('YoutubeMirror: Invidious directory failed: $e');
      return const [];
    }
  }

  Future<List<String>> _loadPipedDirectory() async {
    try {
      final res = await _get('https://piped-instances.kavin.rocks/');
      if (res == null) return const [];
      final data = jsonDecode(res);
      if (data is! List) return const [];
      final out = <String>[];
      for (final entry in data) {
        if (entry is! Map) continue;
        final api = entry['api_url'];
        if (api is String && api.startsWith('https://')) {
          out.add(api.replaceAll(RegExp(r'/+$'), ''));
        }
      }
      return out;
    } catch (e) {
      debugPrint('YoutubeMirror: Piped directory failed: $e');
      return const [];
    }
  }

  // ── Per-server extraction ─────────────────────────────────────────────────

  /// Invidious with local=true returns audio URLs served through the
  /// server itself (so YouTube never sees this device).
  Future<String?> _invidiousAudio(String base, String videoId) async {
    final res = await _get(
        '$base/api/v1/videos/$videoId?local=true&fields=adaptiveFormats');
    if (res == null) return null;
    final data = jsonDecode(res);
    if (data is! Map) return null;
    final formats = data['adaptiveFormats'];
    if (formats is! List) return null;

    final audio = formats
        .whereType<Map>()
        .where((f) => '${f['type'] ?? ''}'.startsWith('audio/') && f['url'] is String)
        .toList()
      ..sort((a, b) => _asInt(b['bitrate']).compareTo(_asInt(a['bitrate'])));
    for (final f in audio.take(2)) {
      var url = f['url'] as String;
      if (url.startsWith('/')) url = '$base$url';
      if (await _plays(url)) return url;
    }
    return null;
  }

  /// Piped returns audio URLs already routed through its own proxy.
  Future<String?> _pipedAudio(String api, String videoId) async {
    final res = await _get('$api/streams/$videoId');
    if (res == null) return null;
    final data = jsonDecode(res);
    if (data is! Map) return null;
    final streams = data['audioStreams'];
    if (streams is! List) return null;

    final audio = streams
        .whereType<Map>()
        .where((s) => s['url'] is String && (s['url'] as String).startsWith('http'))
        .toList()
      ..sort((a, b) => _asInt(b['bitrate']).compareTo(_asInt(a['bitrate'])));
    for (final s in audio.take(2)) {
      final url = s['url'] as String;
      if (await _plays(url)) return url;
    }
    return null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<String?> _get(String url) async {
    try {
      final res = await http.get(Uri.parse(url), headers: {
        'User-Agent': _ua,
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final body = res.body.trimLeft();
      // Blocked/rate-limited servers often answer with an HTML page.
      if (!body.startsWith('{') && !body.startsWith('[')) return null;
      return res.body;
    } catch (_) {
      return null;
    }
  }

  /// Quick check that the audio URL actually serves data, so we don't hand
  /// the player a link that will just fail.
  Future<bool> _plays(String url) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers['User-Agent'] = _ua
        ..headers['Range'] = 'bytes=0-1023';
      final res = await client.send(req).timeout(const Duration(seconds: 5));
      await res.stream.drain<void>().timeout(const Duration(seconds: 3),
          onTimeout: () {});
      return res.statusCode == 200 || res.statusCode == 206;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

class _Mirror {
  final String base;
  final bool isPiped;
  const _Mirror(this.base, {required this.isPiped});

  @override
  bool operator ==(Object other) =>
      other is _Mirror && other.base == base && other.isPiped == isPiped;

  @override
  int get hashCode => Object.hash(base, isPiped);
}

/// Completes with the first non-null result, or null once all have finished.
Future<T?> _firstNonNull<T>(List<Future<T?>> futures) {
  if (futures.isEmpty) return Future.value(null);
  final completer = Completer<T?>();
  var remaining = futures.length;
  for (final f in futures) {
    f.then((value) {
      if (value != null && !completer.isCompleted) completer.complete(value);
    }, onError: (_) {}).whenComplete(() {
      remaining--;
      if (remaining == 0 && !completer.isCompleted) completer.complete(null);
    });
  }
  return completer.future;
}
