import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;
import 'comics_service.dart';
import 'local_server_service.dart';

/// Scraper for readcomicsonline.ru — now the PRIMARY comics source (the
/// previous main source, rcostation.xyz, no longer resolves).
///
/// The site was redesigned (Tailwind markup), so the selectors below were
/// re-derived from the live pages:
///
///   - List:    `GET /comic-list?page=N` (60 comics/page). Each card contains
///              an `<a href="/comic/<slug>">` title link and a cover `<img>`
///              hosted on cdn.readcomicsonline.ru.
///   - Search:  `GET /search?query=<q>` -> JSON
///              `{ suggestions: [{ value, data: slug, cover, url }] }`.
///   - Detail:  `GET /comic/<slug>`. Chapters are `<a href="/comic/<slug>/<n>">`
///              rows containing two child spans: title and date.
///   - Chapter: `GET /comic/<slug>/<n>`. Page images are
///              `.../uploads/manga/<slug>/chapters/<n>/<file>.jpg`.
class ReadComicsOnlineScraper {
  static const String baseUrl = 'https://readcomicsonline.ru';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const String sourceTag = 'rcoru';
  static const Duration _timeout = Duration(seconds: 15);

  /// Returns true if the given URL belongs to this scraper's source.
  static bool ownsUrl(String url) {
    try {
      return Uri.parse(url).host.contains('readcomicsonline.ru');
    } catch (_) {
      return false;
    }
  }

  /// GET with timeout + clear errors. The site sits behind Cloudflare, which
  /// can answer non-browser clients with a "Just a moment..." challenge page.
  static Future<http.Response> _get(Uri uri) async {
    final http.Response res;
    try {
      res = await http.get(uri, headers: {
        'User-Agent': _ua,
        'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      }).timeout(_timeout);
    } on TimeoutException {
      throw ComicsUnavailableException(
          'readcomicsonline.ru took too long to respond. Check your connection or VPN.');
    } catch (e) {
      throw ComicsUnavailableException(
          "Couldn't reach readcomicsonline.ru (${e.runtimeType}). Check your connection, VPN or firewall.");
    }
    if (_looksLikeChallenge(res)) {
      throw ComicsUnavailableException(
          'readcomicsonline.ru is asking for a browser check (Cloudflare), which the app cannot complete. Try again later or from a different network.');
    }
    if (res.statusCode != 200) {
      throw ComicsUnavailableException(
          'readcomicsonline.ru returned HTTP ${res.statusCode}.');
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

  static String _abs(String href) {
    if (href.isEmpty) return href;
    return Uri.parse(baseUrl).resolve(href.trim()).toString();
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  // ── Listing ────────────────────────────────────────────────────────────

  /// One page of the full comic directory (60 comics per page).
  /// Throws [ComicsUnavailableException] if the site can't be read.
  static Future<List<Comic>> getComics({int page = 1}) async {
    final res = await _get(
        Uri.parse('$baseUrl/comic-list').replace(queryParameters: {'page': '$page'}));
    final doc = hp.parse(res.body);

    final comics = <String, Comic>{}; // keyed by slug, keeps site order
    final slugRe = RegExp(r'^/comic/([^/]+)/?$');
    for (final a in doc.querySelectorAll('a[href]')) {
      final path = Uri.parse(_abs(a.attributes['href'] ?? '')).path;
      final m = slugRe.firstMatch(path);
      if (m == null) continue;
      final slug = m.group(1)!;
      final title = _clean(a.text);

      // Find the card element that holds this link and its cover image.
      dom.Element? card = a;
      dom.Element? img;
      for (var i = 0; i < 5 && card != null; i++) {
        img = card.querySelector('img');
        if (img != null) break;
        card = card.parent;
      }

      final existing = comics[slug];
      if (existing != null && (title.isEmpty || existing.title.isNotEmpty)) continue;

      var poster = (img?.attributes['src'] ?? img?.attributes['data-src'] ?? '').trim();
      if (poster.isNotEmpty) poster = _abs(poster);

      comics[slug] = Comic(
        title: title.isNotEmpty ? title : (existing?.title ?? ''),
        url: '$baseUrl/comic/$slug',
        poster: poster.isNotEmpty ? poster : (existing?.poster ?? ''),
        status: '',
        publication: '',
        summary: '',
        source: sourceTag,
      );
    }

    final result = comics.values.where((c) => c.title.isNotEmpty).toList();
    if (result.isEmpty && page == 1) {
      throw ComicsUnavailableException(
          'readcomicsonline.ru loaded but no comics could be read from it — its layout has probably changed again.');
    }
    return result;
  }

  // ── Search ─────────────────────────────────────────────────────────────

  /// Search: returns lightweight Comic objects (poster + slug-based URL).
  static Future<List<Comic>> searchComics(String query) async {
    try {
      final res = await _get(Uri.parse('$baseUrl/search')
          .replace(queryParameters: {'query': query}));

      final body = json.decode(res.body);
      final suggestions = (body is Map && body['suggestions'] is List)
          ? body['suggestions'] as List
          : const [];

      final comics = <Comic>[];
      for (final s in suggestions) {
        if (s is! Map) continue;
        final title = (s['value'] ?? '').toString().trim();
        final slug = (s['data'] ?? '').toString().trim();
        if (title.isEmpty || slug.isEmpty) continue;
        final cover = (s['cover'] ?? '').toString().trim();
        comics.add(Comic(
          title: title,
          url: '$baseUrl/comic/$slug',
          // The cover now lives on cdn.readcomicsonline.ru; the API supplies it.
          poster: cover.isNotEmpty
              ? cover
              : 'https://cdn.readcomicsonline.ru/uploads/manga/$slug/cover/cover_250x350.jpg',
          status: '',
          publication: '',
          summary: '',
          source: sourceTag,
        ));
      }
      return comics;
    } catch (e) {
      debugPrint('[ReadComicsOnline] search error: $e');
      return [];
    }
  }

  // ── Detail ─────────────────────────────────────────────────────────────

  /// Detail page: extracts metadata + full chapter list.
  static Future<ComicDetails?> getComicDetails(Comic comic) async {
    try {
      final res = await _get(Uri.parse(comic.url));
      final doc = hp.parse(res.body);

      final slugMatch =
          RegExp(r'/comic/([^/?#]+)').firstMatch(Uri.parse(comic.url).path);
      final slug = slugMatch?.group(1) ?? '';

      // Header block: status badge + chips (publisher, views) + genres.
      String status = '';
      String publisher = 'Unknown';
      final genres = <String>[];
      final h1 = doc.querySelector('h1');
      final header = h1?.parent;
      if (header != null) {
        for (final span in header.querySelectorAll('span')) {
          if (span.children.isNotEmpty) continue;
          final t = _clean(span.text);
          if (t.isEmpty) continue;
          final cls = span.className;
          if (status.isEmpty && cls.contains('rounded-full') && !cls.contains('bg-brand-500/20')) {
            status = t; // e.g. "Ongoing" / "Completed"
          } else if (cls.contains('rc-chip') && !t.startsWith('👁') && publisher == 'Unknown') {
            publisher = t;
          } else if (t.toLowerCase().startsWith('genres')) {
            genres.addAll(span.parent?.querySelectorAll('a').map((e) => _clean(e.text)) ??
                const <String>[]);
          }
        }
      }

      // Synopsis: the <p> that follows the "Synopsis" heading.
      String summary = '';
      for (final h in doc.querySelectorAll('h3, h2')) {
        if (!h.text.toLowerCase().contains('synopsis')) continue;
        dom.Element? node = h;
        for (var i = 0; i < 3 && node != null && summary.isEmpty; i++) {
          final p = node.parent?.querySelector('p');
          if (p != null) summary = _clean(p.text);
          node = node.parent;
        }
        break;
      }

      // Chapters: rows linking to /comic/<slug>/<n> with title + date spans.
      final chapters = <ComicChapter>[];
      final seen = <String>{};
      final chapRe = RegExp('^/comic/${RegExp.escape(slug)}/[^/]+/?\$');
      for (final a in doc.querySelectorAll('a[href]')) {
        final url = _abs(a.attributes['href'] ?? '');
        if (!chapRe.hasMatch(Uri.parse(url).path)) continue;
        if (a.children.length < 2) continue; // skips "Read First/Last" buttons
        if (!seen.add(url)) continue;
        chapters.add(ComicChapter(
          title: _clean(a.children.first.text),
          url: url,
          dateAdded: _clean(a.children.last.text),
        ));
      }

      final enriched = Comic(
        title: comic.title,
        url: comic.url,
        poster: comic.poster,
        status: status.isNotEmpty ? status : comic.status,
        publication: comic.publication,
        summary: summary.isNotEmpty ? summary : comic.summary,
        source: sourceTag,
      );

      return ComicDetails(
        comic: enriched,
        otherName: 'None',
        genres: genres,
        publisher: publisher,
        writer: 'Unknown',
        artist: 'Unknown',
        publicationDate: 'Unknown',
        chapters: chapters,
      );
    } catch (e) {
      debugPrint('[ReadComicsOnline] detail error: $e');
      return null;
    }
  }

  // ── Chapter pages ──────────────────────────────────────────────────────

  static final RegExp _pageImgRe = RegExp(
    r'''https?://[^"'\s<>]*?/uploads/manga/[^"'\s<>]+/chapters/[^"'\s<>]+?\.(?:jpg|jpeg|png|webp|gif)(?:\?[^"'\s<>]*)?''',
    caseSensitive: false,
  );

  /// Chapter pages: finds the page images on the reader page and wraps each
  /// URL with the local comic-proxy (which adds the required Referer).
  static Future<List<String>> getChapterPages(String chapterUrl) async {
    final res = await _get(Uri.parse(chapterUrl));

    // The page repeats the first image (preload + reader), so de-duplicate
    // while keeping reading order.
    final urls = <String>{};
    for (final m in _pageImgRe.allMatches(res.body)) {
      urls.add(m.group(0)!.replaceAll('&amp;', '&'));
    }

    if (urls.isEmpty) {
      throw Exception('No comic pages found on this chapter page.');
    }

    final proxy = LocalServerService();
    return urls.map(proxy.getComicProxyUrl).toList();
  }
}
