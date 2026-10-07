import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'games_service.dart';

/// Name, cover and description for a game that was just downloaded.
class GameMeta {
  final String? title;
  final String? image;
  final String? description;
  const GameMeta({this.title, this.image, this.description});
  static const empty = GameMeta();
}

/// Finds a clean game name, cover picture and description for a download:
///   1. from the page the download started on (its public "og:" tags, which
///      itch.io, archive.org and most game pages provide),
///   2. otherwise from a very close name match on Steam.
/// Only public pages are fetched, without cookies, and the result is only
/// ever used as text and a picture URL.
class GameMetaResolver {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static final _dropTokens = RegExp(
      r'^(v?\d+([._]\d+)*[a-z]?|pc|win|win32|win64|windows|x64|x86|x86_64|'
      r'64bit|32bit|64|32|mac|macos|osx|linux|installer|setup|portable|'
      r'release|final|build\d*|beta|alpha|demo|full|web|html5|exe|zip)$',
      caseSensitive: false);

  /// "Forgetmenot-1.0-pc.zip" -> "Forgetmenot"
  static String nameFromFileName(String fileName) {
    var n = fileName;
    n = n.replaceFirst(
        RegExp(r'\.(tar\.gz|tar\.bz2|zip|7z|rar|exe|msi|iso|dmg|appimage|apk)$',
            caseSensitive: false),
        '');
    final tokens = n
        .split(RegExp(r'[-_ ]+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final kept = <String>[];
    for (final t in tokens) {
      if (_dropTokens.hasMatch(t) && kept.isNotEmpty) continue;
      kept.add(t);
    }
    final out = kept.join(' ').trim();
    return out.isEmpty ? fileName : out;
  }

  /// Real file name from a Content-Disposition value (or a suggested name
  /// that still contains the raw header), e.g.
  /// `attachment; filename="Forgetmenot-1.0-pc"` -> `Forgetmenot-1.0-pc`.
  static String parseFileName(String? disposition, String? suggested) {
    String? fromHeader(String? h) {
      if (h == null || !h.toLowerCase().contains('filename')) return null;
      final star = RegExp(r"filename\*\s*=\s*[^']*'[^']*'([^;]+)",
              caseSensitive: false)
          .firstMatch(h);
      if (star != null) {
        try {
          return Uri.decodeComponent(star.group(1)!.trim());
        } catch (_) {}
      }
      final q = RegExp(r'filename\s*=\s*"([^"]*)"', caseSensitive: false)
          .firstMatch(h);
      if (q != null) return q.group(1)!.trim();
      final u = RegExp(r'filename\s*=\s*([^;]+)', caseSensitive: false)
          .firstMatch(h);
      return u?.group(1)?.trim();
    }

    var n = fromHeader(suggested) ?? fromHeader(disposition) ?? (suggested ?? '');
    n = n.trim();
    // Keep only the last path part, so a name can never point elsewhere.
    n = n.split(RegExp(r'[\\/]')).last.trim();
    return n;
  }

  static String _decode(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .trim();

  static String? _meta(String html, String key) {
    final k = RegExp.escape(key);
    final a = RegExp(
        '<meta[^>]+(?:property|name)=["\']$k["\'][^>]*content=["\']([^"\']*)["\']',
        caseSensitive: false);
    final b = RegExp(
        '<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:property|name)=["\']$k["\']',
        caseSensitive: false);
    final m = a.firstMatch(html) ?? b.firstMatch(html);
    final v = m?.group(1);
    return (v == null || v.trim().isEmpty) ? null : _decode(v);
  }

  /// Removes site decoration from a page title; null for generic titles.
  static String? cleanTitle(String? raw) {
    if (raw == null) return null;
    var t = raw.trim();
    if (t.isEmpty) return null;
    final fromItch = RegExp(r'itch\.io', caseSensitive: false).hasMatch(t);
    t = t.replaceFirst(RegExp(r'\s*[-|–]\s*itch\.io\s*$', caseSensitive: false), '');
    t = t.replaceFirst(RegExp(r'^Download\s+', caseSensitive: false), '');
    if (fromItch) {
      t = t.replaceFirst(RegExp(r'\s+by\s+[^|]+$', caseSensitive: false), '');
    }
    t = t.trim();
    final lower = t.toLowerCase();
    if (t.isEmpty ||
        lower == 'itch.io' ||
        lower.contains('internet archive') ||
        lower == 'download' ||
        lower == 'home') {
      return null;
    }
    return t.length > 120 ? t.substring(0, 120) : t;
  }

  static List<String> _candidates(String pageUrl) {
    final out = <String>[];
    final u = Uri.tryParse(pageUrl);
    if (u == null || !u.hasScheme || u.host.isEmpty) return out;
    if (u.scheme != 'https' && u.scheme != 'http') return out;
    // itch.io: the download page is <game page>/download/<key>; the game
    // page itself carries the title, cover and description.
    final i = u.path.indexOf('/download');
    if (u.host.endsWith('itch.io') && i > 0) {
      out.add(u.replace(path: u.path.substring(0, i), query: '', fragment: '').toString());
    }
    out.add(pageUrl);
    return out;
  }

  static Future<GameMeta> _fromPage(String pageUrl) async {
    for (final url in _candidates(pageUrl)) {
      try {
        final r = await http
            .get(Uri.parse(url), headers: {'User-Agent': _ua})
            .timeout(const Duration(seconds: 6));
        if (r.statusCode != 200) continue;
        final body = utf8.decode(r.bodyBytes, allowMalformed: true);
        final html = body.length > 300000 ? body.substring(0, 300000) : body;
        final title = cleanTitle(_meta(html, 'og:title') ??
            RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false)
                .firstMatch(html)
                ?.group(1)
                ?.trim());
        var image = _meta(html, 'og:image');
        if (image != null) {
          final iu = Uri.tryParse(image);
          if (iu == null) {
            image = null;
          } else {
            final abs = Uri.parse(url).resolveUri(iu);
            image = abs.scheme == 'https' ? abs.toString() : null;
          }
        }
        final desc = _meta(html, 'og:description') ?? _meta(html, 'description');
        if (title != null || image != null) {
          return GameMeta(title: title, image: image, description: desc);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[GameMeta] $url: $e');
      }
    }
    return GameMeta.empty;
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static double _jaccard(String a, String b) {
    final x = _norm(a).split(' ').where((t) => t.isNotEmpty).toSet();
    final y = _norm(b).split(' ').where((t) => t.isNotEmpty).toSet();
    if (x.isEmpty || y.isEmpty) return 0;
    final inter = x.intersection(y).length;
    return inter / (x.length + y.length - inter);
  }

  /// Steam fallback, accepted only for a very close name match so a wrong
  /// game's picture never gets attached.
  static Future<GameMeta?> _fromSteam(String name) async {
    try {
      final results = await SteamGames.search(name);
      GameInfo? best;
      var bestScore = 0.0;
      for (final g in results) {
        final s = _jaccard(name, g.name);
        if (s > bestScore) {
          bestScore = s;
          best = g;
        }
      }
      if (best == null || bestScore < 0.8) return null;
      final d = await SteamGames.details(best);
      return GameMeta(
          title: d.name,
          image: d.cover,
          description: d.description.isEmpty ? null : d.description);
    } catch (_) {
      return null;
    }
  }

  /// Best available name / cover / description. Never throws.
  static Future<GameMeta> resolve(
      {required String pageUrl, required String fileName}) async {
    var meta = GameMeta.empty;
    try {
      meta = await _fromPage(pageUrl);
      final name = meta.title ?? nameFromFileName(fileName);
      if (meta.image == null || meta.description == null) {
        final steam = await _fromSteam(name);
        if (steam != null) {
          meta = GameMeta(
            title: meta.title ?? steam.title,
            image: meta.image ?? steam.image,
            description: meta.description ?? steam.description,
          );
        }
      }
    } catch (_) {}
    return meta;
  }
}
