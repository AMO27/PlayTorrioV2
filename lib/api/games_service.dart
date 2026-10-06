import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A game as shown in Upcoming and used to fill the Library.
class GameInfo {
  final String id; // "steam:123", "igdb:456" or "manual:<time>"
  final String name;
  final String? cover;
  final List<String> platforms;
  final String releaseDate; // "TBA", "Out now", "12 Nov, 2026", ...
  final String description;
  final List<String> genres;
  final List<String> screenshots;
  final String? trailerUrl; // direct/HLS stream (Steam)
  final String? youtubeId; // IGDB trailers
  final String? trailerThumb;
  final bool detailsLoaded;

  const GameInfo({
    required this.id,
    required this.name,
    this.cover,
    this.platforms = const [],
    this.releaseDate = '',
    this.description = '',
    this.genres = const [],
    this.screenshots = const [],
    this.trailerUrl,
    this.youtubeId,
    this.trailerThumb,
    this.detailsLoaded = true,
  });

  bool get hasTrailer => trailerUrl != null || youtubeId != null;
  String get platformLabel => platforms.join(', ');
}

/// Steam's public store API (no key needed) for PC games.
class SteamGames {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _h = {'User-Agent': _ua, 'Accept-Language': 'en-US,en;q=0.9'};

  static String capsule(String appId) =>
      'https://cdn.cloudflare.steamstatic.com/steam/apps/$appId/header.jpg';

  static Future<dynamic> _json(String url) async {
    final r = await http
        .get(Uri.parse(url), headers: _h)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw 'Steam answered HTTP ${r.statusCode}';
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// Most popular upcoming PC games, most popular first.
  static Future<List<GameInfo>> comingSoon() async {
    final out = <GameInfo>[];
    final seen = <String>{};

    void add(String id, String name) {
      if (name.isEmpty || !seen.add(id)) return;
      out.add(GameInfo(
        id: 'steam:$id',
        name: name,
        cover: capsule(id),
        platforms: const ['PC'],
        releaseDate: 'Coming soon',
        detailsLoaded: false,
      ));
    }

    try {
      final j = await _json(
          'https://store.steampowered.com/search/results/?query&start=0&count=50'
          '&filter=popularcomingsoon&json=1&cc=us&l=en');
      final items = j is Map ? j['items'] : null;
      if (items is List) {
        for (final e in items) {
          if (e is! Map) continue;
          final logo = (e['logo'] ?? '').toString();
          final m = RegExp(r'/apps/(\d+)/').firstMatch(logo);
          if (m == null) continue;
          add(m.group(1)!, (e['name'] ?? '').toString());
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Games] steam search: $e');
    }

    if (out.isEmpty) {
      // Fallback: the store front's "coming soon" shelf.
      final j = await _json(
          'https://store.steampowered.com/api/featuredcategories?cc=us&l=en');
      final items = j is Map && j['coming_soon'] is Map
          ? (j['coming_soon'] as Map)['items']
          : null;
      if (items is List) {
        for (final e in items) {
          if (e is! Map) continue;
          add((e['id'] ?? '').toString(), (e['name'] ?? '').toString());
        }
      }
    }
    return out;
  }

  /// Full details (description, trailer, screenshots, release date).
  static Future<GameInfo> details(GameInfo base) async {
    final id = base.id.replaceFirst('steam:', '');
    final j = await _json(
        'https://store.steampowered.com/api/appdetails?appids=$id&l=en&cc=us');
    final root = j is Map ? j[id] : null;
    final data = root is Map && root['success'] == true ? root['data'] : null;
    if (data is! Map) return base;

    String release = base.releaseDate;
    final rd = data['release_date'];
    if (rd is Map) {
      final date = (rd['date'] ?? '').toString().trim();
      if (rd['coming_soon'] == true) {
        release = date.isEmpty || date.toLowerCase() == 'coming soon'
            ? 'TBA'
            : date;
      } else {
        release = date.isEmpty ? 'Out now' : '$date (out now)';
      }
    }

    String? trailer;
    String? thumb;
    final movies = data['movies'];
    if (movies is List && movies.isNotEmpty && movies.first is Map) {
      final m = movies.first as Map;
      thumb = m['thumbnail']?.toString();
      final hls = m['hls_h264']?.toString();
      final mp4 = m['mp4'] is Map ? (m['mp4'] as Map)['max']?.toString() : null;
      trailer = (hls != null && hls.isNotEmpty) ? hls : mp4;
    }

    final shots = <String>[];
    final ss = data['screenshots'];
    if (ss is List) {
      for (final s in ss) {
        if (s is Map && s['path_full'] != null) {
          shots.add(s['path_full'].toString());
        }
      }
    }
    final genres = <String>[];
    final gs = data['genres'];
    if (gs is List) {
      for (final g in gs) {
        if (g is Map && g['description'] != null) {
          genres.add(g['description'].toString());
        }
      }
    }

    return GameInfo(
      id: base.id,
      name: (data['name'] ?? base.name).toString(),
      cover: (data['header_image'] ?? base.cover)?.toString(),
      platforms: const ['PC'],
      releaseDate: release,
      description: (data['short_description'] ?? '').toString(),
      genres: genres,
      screenshots: shots,
      trailerUrl: trailer,
      trailerThumb: thumb,
      detailsLoaded: true,
    );
  }

  /// Search by name (used by the Library's add dialog).
  static Future<List<GameInfo>> search(String q) async {
    final j = await _json(
        'https://store.steampowered.com/api/storesearch/?term=${Uri.encodeQueryComponent(q)}&l=en&cc=us');
    final items = j is Map ? j['items'] : null;
    final out = <GameInfo>[];
    if (items is List) {
      for (final e in items) {
        if (e is! Map) continue;
        final id = (e['id'] ?? '').toString();
        if (id.isEmpty) continue;
        out.add(GameInfo(
          id: 'steam:$id',
          name: (e['name'] ?? '').toString(),
          cover: capsule(id),
          platforms: const ['PC'],
          detailsLoaded: false,
        ));
      }
    }
    return out;
  }
}

/// IGDB (owned by Twitch) for console games. Needs a free Twitch Client ID
/// and Client Secret, pasted in Settings and kept only on this device.
class IgdbGames {
  static const _idKey = 'igdb_client_id';
  static const _secretKey = 'igdb_client_secret';

  // PS5, Xbox Series X|S, Switch, Switch 2.
  static const _consoleIds = '(167,169,130,508)';

  static String? _token;
  static DateTime _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<(String, String)?> credentials() async {
    final p = await SharedPreferences.getInstance();
    final id = (p.getString(_idKey) ?? '').trim();
    final secret = (p.getString(_secretKey) ?? '').trim();
    if (id.isEmpty || secret.isEmpty) return null;
    return (id, secret);
  }

  static Future<void> saveCredentials(String id, String secret) async {
    final p = await SharedPreferences.getInstance();
    if (id.trim().isEmpty && secret.trim().isEmpty) {
      await p.remove(_idKey);
      await p.remove(_secretKey);
    } else {
      await p.setString(_idKey, id.trim());
      await p.setString(_secretKey, secret.trim());
    }
    _token = null;
  }

  static Future<bool> hasCredentials() async => (await credentials()) != null;

  /// Gets a Twitch app token. Throws a readable message on failure.
  static Future<String> _auth(String id, String secret) async {
    if (_token != null && DateTime.now().isBefore(_tokenExpiry)) return _token!;
    final r = await http.post(
      Uri.parse('https://id.twitch.tv/oauth2/token'),
      body: {
        'client_id': id,
        'client_secret': secret,
        'grant_type': 'client_credentials',
      },
    ).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw 'Twitch rejected the Client ID / Secret (HTTP ${r.statusCode})';
    }
    final j = jsonDecode(r.body);
    _token = (j['access_token'] ?? '').toString();
    final secs = (j['expires_in'] is num) ? (j['expires_in'] as num).toInt() : 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: secs - 120));
    if (_token!.isEmpty) throw 'Twitch returned no token';
    return _token!;
  }

  static Future<List<dynamic>> _query(String body) async {
    final c = await credentials();
    if (c == null) throw 'No IGDB keys saved';
    final token = await _auth(c.$1, c.$2);
    final r = await http
        .post(
          Uri.parse('https://api.igdb.com/v4/games'),
          headers: {
            'Client-ID': c.$1,
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) throw 'IGDB answered HTTP ${r.statusCode}';
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return j is List ? j : const [];
  }

  static const _fields =
      'fields name,summary,hypes,first_release_date,cover.image_id,'
      'platforms.abbreviation,platforms.name,genres.name,'
      'screenshots.image_id,videos.video_id,release_dates.human;';

  static String _img(String size, String id) =>
      'https://images.igdb.com/igdb/image/upload/t_$size/$id.jpg';

  static GameInfo _parse(Map e) {
    final ts = e['first_release_date'];
    String release = 'TBA';
    if (ts is num) {
      final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000, isUtc: true);
      const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      release = d.isBefore(DateTime.now().toUtc())
          ? 'Out now'
          : '${d.day} ${m[d.month - 1]}, ${d.year}';
    }
    List<String> names(String key, String field) {
      final l = e[key];
      if (l is! List) return const [];
      return l
          .whereType<Map>()
          .map((x) => (x[field] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList();
    }

    final plats = <String>[];
    final pl = e['platforms'];
    if (pl is List) {
      for (final p in pl.whereType<Map>()) {
        final n = (p['abbreviation'] ?? p['name'] ?? '').toString();
        if (n.isNotEmpty && !plats.contains(n)) plats.add(n);
      }
    }
    final coverId = e['cover'] is Map ? (e['cover'] as Map)['image_id']?.toString() : null;
    final shots = names('screenshots', 'image_id').map((i) => _img('screenshot_big', i)).toList();
    final vids = names('videos', 'video_id');
    return GameInfo(
      id: 'igdb:${e['id']}',
      name: (e['name'] ?? '').toString(),
      cover: coverId == null ? null : _img('cover_big', coverId),
      platforms: plats,
      releaseDate: release,
      description: (e['summary'] ?? '').toString(),
      genres: names('genres', 'name'),
      screenshots: shots,
      youtubeId: vids.isEmpty ? null : vids.first,
      trailerThumb: vids.isEmpty ? null : 'https://img.youtube.com/vi/${vids.first}/hqdefault.jpg',
    );
  }

  /// Most hyped upcoming console games (PS5, Xbox Series, Switch).
  static Future<List<GameInfo>> upcoming() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final list = await _query(
        '$_fields where (first_release_date > $now | first_release_date = null) '
        '& hypes > 0 & platforms = $_consoleIds; sort hypes desc; limit 50;');
    return list.whereType<Map>().map(_parse).where((g) => g.name.isNotEmpty).toList();
  }

  static Future<List<GameInfo>> search(String q) async {
    final safe = q.replaceAll('"', ' ');
    final list = await _query('$_fields search "$safe"; where platforms != null; limit 15;');
    return list.whereType<Map>().map(_parse).where((g) => g.name.isNotEmpty).toList();
  }
}
