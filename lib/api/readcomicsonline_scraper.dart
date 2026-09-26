import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;
import 'comics_service.dart';
import 'local_server_service.dart';

/// Scraper for readcomiconline.xyz (WordPress / MangaStream-style theme).
///
///   - List:    `GET /manga/?page=N` -> `.listupd .bsx a[title]` cards.
///   - Search:  `GET /?s=<q>` -> same card markup.
///   - Detail:  `GET /manga/<slug>/` -> `#chapterlist li a` rows.
///   - Chapter: `GET /<slug>-issue-N/` -> `ts_reader.run({...sources:[{images:[...]}]})`.
class ReadComicsOnlineScraper {
  static const String host = 'readcomiconline.xyz';
  static const String baseUrl = 'https://readcomiconline.xyz';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const String sourceTag = 'rcoxyz';
  static const Duration _timeout = Duration(seconds: 15);

  static bool ownsUrl(String url) {
    try {
      return Uri.parse(url).host.contains(host);
    } catch (_) {
      return false;
    }
  }

  static Future<http.Response> _get(Uri uri) async {
    final http.Response res;
    try {
      res = await http.get(uri, headers: {
        'User-Agent': _ua,
        'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      }).timeout(_timeout);
    } on TimeoutException {
      throw ComicsUnavailableException(
          '$host took too long to respond. Check your connection or VPN.');
    } catch (e) {
      throw ComicsUnavailableException(
          "Couldn't reach $host (${e.runtimeType}). Check your connection, VPN or firewall.");
    }
    if (_looksLikeChallenge(res)) {
      throw ComicsUnavailableException(
          '$host is asking for a browser check (Cloudflare), which the app cannot complete. Use "Open in browser" instead, or try again later.');
    }
    if (res.statusCode != 200) {
      throw ComicsUnavailableException('$host returned HTTP ${res.statusCode}.');
    }
    return res;
  }

  static bool _looksLikeChallenge(http.Response res) {
    if (res.statusCode == 403 || res.statusCode == 503) return true;
    final head = res.body.length > 4000 ? res.body.substring(0, 4000) : res.body;
    return head.contains('<title>Just a moment') ||
        head.contains('cf-browser-verification') ||
        head.contains('challenges.cloudflare.com');
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static List<Comic> _parseCards(dom.Document doc) {
    final out = <Comic>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('.listupd .bsx a[href]')) {
      final href = (a.attributes['href'] ?? '').trim();
      if (href.isEmpty || !seen.add(href)) continue;
      var title = _clean(a.attributes['title'] ?? '');
      if (title.isEmpty) title = _clean(a.querySelector('.tt')?.text ?? '');
      if (title.isEmpty) continue;
      final img = a.querySelector('img');
      final poster = (img?.attributes['src'] ?? img?.attributes['data-src'] ?? '').trim();
      out.add(Comic(
        title: title,
        url: href,
        poster: poster,
        status: '',
        publication: '',
        summary: '',
        source: sourceTag,
      ));
    }
    return out;
  }

  /// One page of the directory (30 comics/page).
  static Future<List<Comic>> getComics({int page = 1}) async {
    final res = await _get(Uri.parse('$baseUrl/manga/')
        .replace(queryParameters: {'page': '$page'}));
    final comics = _parseCards(hp.parse(res.body));
    if (comics.isEmpty && page == 1) {
      throw ComicsUnavailableException(
          '$host loaded but no comics could be read from it — its layout has probably changed.');
    }
    return comics;
  }

  static Future<List<Comic>> searchComics(String query) async {
    try {
      final res = await _get(
          Uri.parse('$baseUrl/').replace(queryParameters: {'s': query}));
      return _parseCards(hp.parse(res.body));
    } catch (e) {
      debugPrint('[ReadComicsOnline] search error: $e');
      return [];
    }
  }

  static String _info(dom.Document doc, String label) {
    for (final e in doc.querySelectorAll('.imptdt')) {
      final t = _clean(e.text);
      if (t.toLowerCase().startsWith(label.toLowerCase())) {
        return _clean(t.substring(label.length));
      }
    }
    return '';
  }

  static Future<ComicDetails?> getComicDetails(Comic comic) async {
    try {
      final res = await _get(Uri.parse(comic.url));
      final doc = hp.parse(res.body);

      final status = _info(doc, 'Status');
      final artist = _info(doc, 'Artist');
      final released = _info(doc, 'Released');
      final genres = doc.querySelectorAll('.mgen a').map((e) => _clean(e.text)).toList();
      final summary = _clean(doc.querySelector('.entry-content-single')?.text ??
          doc.querySelector('[itemprop=description]')?.text ??
          '');

      final chapters = <ComicChapter>[];
      final seen = <String>{};
      for (final a in doc.querySelectorAll('#chapterlist li a[href]')) {
        final url = (a.attributes['href'] ?? '').trim();
        if (url.isEmpty || !seen.add(url)) continue;
        chapters.add(ComicChapter(
          title: _clean(a.querySelector('.chapternum')?.text ?? a.text),
          url: url,
          dateAdded: _clean(a.querySelector('.chapterdate')?.text ?? ''),
        ));
      }

      return ComicDetails(
        comic: Comic(
          title: comic.title,
          url: comic.url,
          poster: comic.poster,
          status: status.isNotEmpty ? status : comic.status,
          publication: comic.publication,
          summary: summary.isNotEmpty ? summary : comic.summary,
          source: sourceTag,
        ),
        otherName: 'None',
        genres: genres,
        publisher: 'Unknown',
        writer: 'Unknown',
        artist: artist.isNotEmpty ? artist : 'Unknown',
        publicationDate: released.isNotEmpty ? released : 'Unknown',
        chapters: chapters,
      );
    } catch (e) {
      debugPrint('[ReadComicsOnline] detail error: $e');
      return null;
    }
  }

  /// Chapter pages come from the `ts_reader.run({...})` JSON in the page.
  static Future<List<String>> getChapterPages(String chapterUrl) async {
    final res = await _get(Uri.parse(chapterUrl));
    final body = res.body;
    final urls = <String>[];

    final start = body.indexOf('ts_reader.run(');
    if (start >= 0) {
      final open = body.indexOf('{', start);
      // Walk to the matching closing brace (ignoring braces inside strings).
      var depth = 0;
      var inStr = false;
      var esc = false;
      var end = -1;
      for (var i = open; i < body.length; i++) {
        final c = body[i];
        if (inStr) {
          if (esc) {
            esc = false;
          } else if (c == r'\') {
            esc = true;
          } else if (c == '"') {
            inStr = false;
          }
        } else if (c == '"') {
          inStr = true;
        } else if (c == '{') {
          depth++;
        } else if (c == '}') {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }
      if (open >= 0 && end > open) {
        try {
          final data = json.decode(body.substring(open, end + 1));
          final sources = data['sources'];
          if (sources is List && sources.isNotEmpty) {
            final imgs = sources.first['images'];
            if (imgs is List) urls.addAll(imgs.map((e) => e.toString()));
          }
        } catch (e) {
          debugPrint('[ReadComicsOnline] ts_reader parse error: $e');
        }
      }
    }

    if (urls.isEmpty) {
      throw Exception('No comic pages found on this chapter page.');
    }
    final proxy = LocalServerService();
    return urls.map(proxy.getComicProxyUrl).toList();
  }
}
