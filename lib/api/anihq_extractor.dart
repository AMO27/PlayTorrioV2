import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Extractor for anihq.cc.
///
/// anihq.cc is a plain WordPress site (no bot check). Its public WordPress
/// search API returns episode pages directly, titled
/// "<Show> Episode <N> English Subbed|Dubbed". Each episode page carries a
/// Pixeldrain download link, and Pixeldrain serves the file straight over
/// HTTP (`/api/file/<id>`, range requests supported), so no decryption or
/// player scraping is needed.
///
/// Pipeline:
///   1. GET /wp-json/wp/v2/search?search=<title> episode <N>&subtype=episode
///   2. Keep results whose title ends in "Episode <N> English Subbed|Dubbed"
///      for the wanted category; score the show-name part against our titles.
///   3. GET the best episode page and read `pixeldrain.com/u/<id>`.
class AniHqResult {
  final String url;
  final String referer;
  final String origin;
  AniHqResult({required this.url, required this.referer, required this.origin});
}

class AniHqExtractor {
  static const _site = 'https://anihq.cc';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const _stopwords = <String>{
    'a', 'an', 'the', 'of', 'and', 'or', 'to', 'in', 'on', 'at',
    'for', 'with', 'by', 'from', 'is', 'it',
    'no', 'wa', 'ga', 'ni', 'o', 'wo', 'de', 'mo', 'ka', 'ya',
    'na', 'e', 'he', 'te', 'ne',
    'anime', 'tv', 'english', 'subbed', 'dubbed', 'sub', 'dub',
    'episode', 'ep',
  };

  /// Why the last attempt failed, for the on-screen error list.
  final Map<String, String> notes = {};

  final HttpClient _http = HttpClient()
    ..userAgent = _ua
    ..connectionTimeout = const Duration(seconds: 15);

  Future<String?> _get(String url, {bool json = false}) async {
    final req = await _http.getUrl(Uri.parse(url));
    req.headers
      ..set('User-Agent', _ua)
      ..set('Accept', json ? 'application/json' : 'text/html,*/*')
      ..set('Accept-Language', 'en-US,en;q=0.9')
      ..set('Referer', '$_site/');
    final res = await req.close().timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw 'AniHQ answered HTTP ${res.statusCode}';
    }
    return res.transform(const Utf8Decoder(allowMalformed: true)).join();
  }

  String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#038;', '&')
      .replaceAll('&#8211;', '-')
      .replaceAll('&#8217;', "'")
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)));

  Set<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .split(' ')
      .where((t) => t.isNotEmpty && !_stopwords.contains(t))
      .toSet();

  double _score(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final inter = a.intersection(b).length;
    if (inter == 0) return 0;
    return inter / (a.length + b.length - inter);
  }

  Future<AniHqResult?> extract({
    required List<String> titleCandidates,
    required int episode,
    required String category, // 'sub' | 'dub'
  }) async {
    final key = category;
    notes.remove(key);
    try {
      final wantedWord = category == 'dub' ? 'Dubbed' : 'Subbed';
      final tail = RegExp(
          r'^(.*?)\s+Episode\s+(\d+)\s+English\s+(Subbed|Dubbed)\s*$',
          caseSensitive: false);

      final queries = <String>[];
      for (final t in titleCandidates) {
        final c = t.trim();
        if (c.isEmpty) continue;
        // The part before ':' is usually enough and matches more reliably.
        final short = c.split(RegExp(r'[:–—]')).first.trim();
        for (final q in {c, short}) {
          if (q.isNotEmpty && !queries.contains(q)) queries.add(q);
        }
      }
      if (queries.isEmpty) {
        notes[key] = 'no title to search with';
        return null;
      }

      String? bestUrl;
      double bestScore = 0;
      final wantedSets = titleCandidates.map(_tokens).toList();

      for (final q in queries.take(4)) {
        final api = '$_site/wp-json/wp/v2/search'
            '?search=${Uri.encodeQueryComponent('$q episode $episode')}'
            '&subtype=episode&per_page=30';
        final body = await _get(api, json: true);
        final list = body == null ? null : jsonDecode(body);
        if (list is! List) continue;
        for (final e in list) {
          if (e is! Map) continue;
          final title = _decodeEntities((e['title'] ?? '').toString());
          final url = (e['url'] ?? '').toString();
          final m = tail.firstMatch(title);
          if (m == null || url.isEmpty) continue;
          if (int.tryParse(m.group(2)!) != episode) continue;
          if (m.group(3)!.toLowerCase() != wantedWord.toLowerCase()) continue;
          final name = _tokens(m.group(1)!);
          var s = 0.0;
          for (final w in wantedSets) {
            final v = _score(name, w);
            if (v > s) s = v;
          }
          if (s > bestScore) {
            bestScore = s;
            bestUrl = url;
          }
        }
        if (bestScore >= 0.99) break;
      }

      if (bestUrl == null || bestScore < 0.45) {
        notes[key] = "couldn't find this episode on AniHQ ($category)";
        return null;
      }

      final page = await _get(bestUrl);
      final m = RegExp(r'pixeldrain\.com/u/([A-Za-z0-9_-]+)')
          .firstMatch(page ?? '');
      if (m == null) {
        notes[key] = 'episode page on AniHQ has no direct file link';
        return null;
      }
      final id = m.group(1)!;
      if (kDebugMode) debugPrint('[AniHQ] $bestUrl -> pixeldrain $id');
      return AniHqResult(
        url: 'https://pixeldrain.com/api/file/$id',
        referer: '$_site/',
        origin: _site,
      );
    } catch (e) {
      notes[key] = '$e';
      if (kDebugMode) debugPrint('[AniHQ] failed: $e');
      return null;
    }
  }

  void dispose() {
    _http.close(force: true);
  }
}
