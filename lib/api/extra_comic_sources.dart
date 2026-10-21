import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;
import 'package:http/http.dart' as http;
import 'comics_service.dart';
import 'local_server_service.dart';

/// Shared helpers for the extra comic sources below.
class _Web {
  static const String ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const Duration timeout = Duration(seconds: 15);

  static String clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static Future<String> get(String host, Uri uri) async {
    final http.Response res;
    try {
      res = await http.get(uri, headers: {
        'User-Agent': ua,
        'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://$host/',
      }).timeout(timeout);
    } on TimeoutException {
      throw ComicsUnavailableException(
          '$host took too long to respond. Check your connection or VPN.');
    } catch (e) {
      throw ComicsUnavailableException(
          "Couldn't reach $host (${e.runtimeType}). Check your connection, VPN or firewall.");
    }
    final head = res.body.length > 4000 ? res.body.substring(0, 4000) : res.body;
    final looksLikeCheck = head.contains('<title>Just a moment') ||
        head.contains('challenges.cloudflare.com') ||
        head.contains('cf-browser-verification') ||
        head.contains('ddos-guard');
    if (res.statusCode != 200 || looksLikeCheck) {
      // Record exactly what came back so the debug log shows the real cause.
      final snippet = head.replaceAll(RegExp(r'\s+'), ' ').trim();
      debugPrint('[$host] request failed: HTTP ${res.statusCode} '
          'server=${res.headers['server']} url=$uri body=${snippet.length > 160 ? snippet.substring(0, 160) : snippet}');
    }
    if (looksLikeCheck || res.statusCode == 403 || res.statusCode == 503) {
      throw ComicsUnavailableException(
          '$host refused the app (HTTP ${res.statusCode}${looksLikeCheck ? ', browser check' : ''}). Try again later or open it in your browser.');
    }
    if (res.statusCode != 200) {
      throw ComicsUnavailableException('$host returned HTTP ${res.statusCode}.');
    }
    return res.body;
  }

  static String imgOf(dom.Element? img) {
    if (img == null) return '';
    for (final k in ['data-src', 'data-lazy-src', 'data-original', 'src']) {
      final v = (img.attributes[k] ?? '').trim();
      if (v.isNotEmpty && !v.startsWith('data:')) return v;
    }
    return '';
  }

  static String absolute(String base, String url) {
    if (url.isEmpty || url.startsWith('http')) return url;
    if (url.startsWith('//')) return 'https:$url';
    return url.startsWith('/') ? '$base$url' : '$base/$url';
  }
}

// ---------------------------------------------------------------------------
// readfreecomicsonline.com — WordPress, one post per issue, plain <img> pages.
// ---------------------------------------------------------------------------
class ReadFreeComicsScraper {
  static const String host = 'readfreecomicsonline.com';
  static const String baseUrl = 'https://readfreecomicsonline.com';
  static const String sourceTag = 'rfco';

  static bool ownsUrl(String url) => url.contains(host);

  static List<Comic> _cards(String body) {
    final out = <Comic>[];
    final seen = <String>{};
    for (final a in hp.parse(body).querySelectorAll('article')) {
      final link = a.querySelector('.entry-title a') ?? a.querySelector('a[href]');
      final href = (link?.attributes['href'] ?? '').trim();
      final title = _Web.clean(link?.text ?? '');
      if (href.isEmpty || title.isEmpty || !seen.add(href)) continue;
      out.add(Comic(
        title: title,
        url: href,
        poster: _Web.imgOf(a.querySelector('img')),
        status: '',
        publication: '',
        summary: '',
        source: sourceTag,
      ));
    }
    return out;
  }

  static Future<List<Comic>> getComics({int page = 1}) async {
    final url = page <= 1 ? '$baseUrl/' : '$baseUrl/page/$page/';
    final comics = _cards(await _Web.get(host, Uri.parse(url)));
    if (comics.isEmpty && page == 1) {
      throw ComicsUnavailableException(
          '$host loaded but no comics could be read from it — its layout has probably changed.');
    }
    return comics;
  }

  static Future<List<Comic>> searchComics(String query) async {
    try {
      final body = await _Web.get(
          host, Uri.parse('$baseUrl/').replace(queryParameters: {'s': query}));
      return _cards(body);
    } catch (e) {
      debugPrint('[ReadFreeComics] search error: $e');
      return [];
    }
  }

  /// Every post here is a single issue, so the "series" has one chapter: itself.
  static Future<ComicDetails?> getComicDetails(Comic comic) async {
    final body = await _Web.get(host, Uri.parse(comic.url));
    final doc = hp.parse(body);
    final genres = doc
        .querySelectorAll('a[rel="category tag"], .cat-links a')
        .map((e) => _Web.clean(e.text))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    final date = _Web.clean(doc.querySelector('time')?.text ?? '');
    return ComicDetails(
      comic: Comic(
        title: comic.title,
        url: comic.url,
        poster: comic.poster,
        status: comic.status,
        publication: comic.publication,
        summary: comic.summary,
        source: sourceTag,
      ),
      otherName: 'None',
      genres: genres,
      publisher: 'Unknown',
      writer: 'Unknown',
      artist: 'Unknown',
      publicationDate: date.isNotEmpty ? date : 'Unknown',
      chapters: [
        ComicChapter(title: comic.title, url: comic.url, dateAdded: date),
      ],
    );
  }

  static Future<List<String>> getChapterPages(String chapterUrl) async {
    final doc = hp.parse(await _Web.get(host, Uri.parse(chapterUrl)));
    final urls = <String>[];
    for (final img in doc.querySelectorAll('.entry-content img')) {
      final u = _Web.imgOf(img);
      if (u.contains('/wp-content/uploads/') && !urls.contains(u)) urls.add(u);
    }
    if (urls.isEmpty) {
      throw Exception('No comic pages found on this page.');
    }
    final proxy = LocalServerService();
    return urls.map(proxy.getComicProxyUrl).toList();
  }
}

// ---------------------------------------------------------------------------
// batcave.biz — DLE site. Series page holds the chapter list in `__DATA__`,
// the reader page holds the signed page image URLs in `__DATA__.images`.
// ---------------------------------------------------------------------------
class BatcaveScraper {
  static const String host = 'batcave.biz';
  static const String baseUrl = 'https://batcave.biz';
  static const String sourceTag = 'batcave';

  static bool ownsUrl(String url) => url.contains(host);

  static List<Comic> _cards(String body) {
    final out = <Comic>[];
    final seen = <String>{};
    final doc = hp.parse(body);
    for (final card in doc.querySelectorAll('.readed, a.poster')) {
      final link = card.localName == 'a' && card.attributes['href'] != null
          ? card
          : card.querySelector('a[href\$=".html"]');
      var href = (link?.attributes['href'] ?? '').trim();
      if (href.isEmpty || !href.endsWith('.html')) continue;
      href = _Web.absolute(baseUrl, href);
      if (!seen.add(href)) continue;
      final img = card.querySelector('img');
      var title = _Web.clean(card.querySelector('.readed__title')?.text ?? '');
      if (title.isEmpty) title = _Web.clean(img?.attributes['alt'] ?? '');
      if (title.isEmpty) continue;
      out.add(Comic(
        title: title,
        url: href,
        poster: _Web.absolute(baseUrl, _Web.imgOf(img)),
        status: '',
        publication: '',
        summary: '',
        source: sourceTag,
      ));
    }
    return out;
  }

  static Future<List<Comic>> _list(String path, int page) async {
    final url = page <= 1 ? '$baseUrl$path' : '$baseUrl${path}page/$page/';
    final comics = _cards(await _Web.get(host, Uri.parse(url)));
    if (comics.isEmpty && page == 1) {
      throw ComicsUnavailableException(
          '$host loaded but no comics could be read from it — its layout has probably changed.');
    }
    return comics;
  }

  static Future<List<Comic>> getComics({int page = 1}) => _list('/comix/', page);

  static Future<List<Comic>> getTrendingComics({int page = 1}) =>
      _list('/watched/', page);

  static Future<List<Comic>> searchComics(String query) async {
    try {
      final body = await _Web.get(
          host,
          Uri.parse('$baseUrl/').replace(queryParameters: {
            'do': 'search',
            'subaction': 'search',
            'story': query,
          }));
      return _cards(body);
    } catch (e) {
      debugPrint('[BatCave] search error: $e');
      return [];
    }
  }

  /// Pulls the JSON object assigned to `__DATA__` out of a page.
  static Map<String, dynamic>? _dataOf(String body) {
    final start = body.indexOf('__DATA__');
    if (start < 0) return null;
    final open = body.indexOf('{', start);
    if (open < 0) return null;
    var depth = 0;
    var inStr = false;
    var esc = false;
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
          try {
            final v = json.decode(body.substring(open, i + 1));
            return v is Map<String, dynamic> ? v : null;
          } catch (e) {
            debugPrint('[BatCave] __DATA__ parse error: $e');
            return null;
          }
        }
      }
    }
    return null;
  }

  static Future<ComicDetails?> getComicDetails(Comic comic) async {
    final body = await _Web.get(host, Uri.parse(comic.url));
    final doc = hp.parse(body);
    final data = _dataOf(body);
    final newsId = data?['news_id']?.toString() ?? '';
    final chapters = <ComicChapter>[];
    final list = data?['chapters'];
    if (newsId.isNotEmpty && list is List) {
      for (final c in list) {
        if (c is! Map || c['broken'] == true) continue;
        chapters.add(ComicChapter(
          title: _Web.clean(c['title']?.toString() ?? 'Issue'),
          url: '$baseUrl/reader/$newsId/${c['id']}',
          dateAdded: c['date']?.toString() ?? '',
        ));
      }
    }
    if (chapters.isEmpty) {
      throw ComicsUnavailableException(
          'No issues could be read from this BatCave page.');
    }
    final summary = _Web.clean(doc.querySelector('.page__text, .full-text, [itemprop=description]')?.text ?? '');
    return ComicDetails(
      comic: Comic(
        title: comic.title,
        url: comic.url,
        poster: comic.poster,
        status: comic.status,
        publication: comic.publication,
        summary: summary.isNotEmpty ? summary : comic.summary,
        source: sourceTag,
      ),
      otherName: 'None',
      genres: const [],
      publisher: 'Unknown',
      writer: 'Unknown',
      artist: 'Unknown',
      publicationDate: 'Unknown',
      chapters: chapters,
    );
  }

  static Future<List<String>> getChapterPages(String chapterUrl) async {
    final body = await _Web.get(host, Uri.parse(chapterUrl));
    final data = _dataOf(body);
    final images = data?['images'];
    final urls = <String>[];
    if (images is List) {
      for (final i in images) {
        final u = i.toString();
        if (u.startsWith('http')) urls.add(u);
      }
    }
    if (urls.isEmpty) {
      throw Exception('No comic pages found on this BatCave issue.');
    }
    final proxy = LocalServerService();
    return urls.map(proxy.getComicProxyUrl).toList();
  }
}

// ---------------------------------------------------------------------------
// getcomics.org — the download source. Each "chapter" in the details screen is
// a download button; "DOWNLOAD NOW" is saved by the app itself, the mirror
// buttons open in the browser.
// ---------------------------------------------------------------------------
class GetComicsScraper {
  static const String host = 'getcomics.org';
  static const String baseUrl = 'https://getcomics.org';
  static const String sourceTag = 'getcomics';

  static bool ownsUrl(String url) => url.contains(host);

  static List<Comic> _cards(String body) {
    final out = <Comic>[];
    final seen = <String>{};
    for (final a in hp.parse(body).querySelectorAll('article')) {
      final link = a.querySelector('.post-title a, h1 a, h2 a') ?? a.querySelector('a[href]');
      final href = (link?.attributes['href'] ?? '').trim();
      final title = _Web.clean(link?.text ?? '');
      if (href.isEmpty || title.isEmpty || !seen.add(href)) continue;
      final info = _Web.clean(a.querySelector('.post-info, p')?.text ?? '');
      out.add(Comic(
        title: title,
        url: href,
        poster: _Web.imgOf(a.querySelector('img')),
        status: '',
        publication: '',
        summary: info,
        source: sourceTag,
      ));
    }
    return out;
  }

  static Future<List<Comic>> getComics({int page = 1}) async {
    final url = page <= 1 ? '$baseUrl/' : '$baseUrl/page/$page/';
    final comics = _cards(await _Web.get(host, Uri.parse(url)));
    if (comics.isEmpty && page == 1) {
      throw ComicsUnavailableException(
          '$host loaded but no comics could be read from it — its layout has probably changed.');
    }
    return comics;
  }

  static Future<List<Comic>> searchComics(String query) async {
    try {
      final body = await _Web.get(
          host, Uri.parse('$baseUrl/').replace(queryParameters: {'s': query}));
      return _cards(body);
    } catch (e) {
      debugPrint('[GetComics] search error: $e');
      return [];
    }
  }

  static Future<ComicDetails?> getComicDetails(Comic comic) async {
    final body = await _Web.get(host, Uri.parse(comic.url));
    final doc = hp.parse(body);
    final links = <ComicChapter>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll(
        '.aio-button-center a, a.aio-red, a.aio-blue, a.aio-purple, a.aio-green, a.aio-orange')) {
      final href = (a.attributes['href'] ?? '').trim();
      if (!href.startsWith('http') || !seen.add(href)) continue;
      final label = _Web.clean(a.text);
      links.add(ComicChapter(
        title: label.isNotEmpty ? 'Download — $label' : 'Download',
        url: href,
        dateAdded: _Web.clean(a.attributes['title'] ?? ''),
      ));
    }
    if (links.isEmpty) {
      throw ComicsUnavailableException(
          'No download links were found on this GetComics page.');
    }
    final summary = _Web.clean(doc.querySelector('.post-contents p')?.text ?? '');
    return ComicDetails(
      comic: Comic(
        title: comic.title,
        url: comic.url,
        poster: comic.poster,
        status: comic.status,
        publication: comic.publication,
        summary: summary.isNotEmpty ? summary : comic.summary,
        source: sourceTag,
      ),
      otherName: 'None',
      genres: const [],
      publisher: 'Unknown',
      writer: 'Unknown',
      artist: 'Unknown',
      publicationDate: 'Unknown',
      chapters: links,
    );
  }
}
