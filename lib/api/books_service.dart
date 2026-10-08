import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as hp;
import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

class BookResult {
  final String title;
  final String series;
  final String author;
  final String publisher;
  final String year;
  final String language;
  final String pages;
  final String size;
  final String format;
  final String isbn;
  final String editionId;
  final String editionUrl;
  final String fileId;
  final List<Map<String, String>> downloadLinks;

  const BookResult({
    required this.title,
    required this.series,
    required this.author,
    required this.publisher,
    required this.year,
    required this.language,
    required this.pages,
    required this.size,
    required this.format,
    required this.isbn,
    required this.editionId,
    required this.editionUrl,
    required this.fileId,
    required this.downloadLinks,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'series': series,
    'author': author,
    'publisher': publisher,
    'year': year,
    'language': language,
    'pages': pages,
    'size': size,
    'format': format,
    'isbn': isbn,
    'editionId': editionId,
    'editionUrl': editionUrl,
    'fileId': fileId,
    'downloadLinks': downloadLinks,
  };

  factory BookResult.fromJson(Map<String, dynamic> json) => BookResult(
    title: json['title'] ?? '',
    series: json['series'] ?? '',
    author: json['author'] ?? '',
    publisher: json['publisher'] ?? '',
    year: json['year'] ?? '',
    language: json['language'] ?? '',
    pages: json['pages'] ?? '',
    size: json['size'] ?? '',
    format: json['format'] ?? '',
    isbn: json['isbn'] ?? '',
    editionId: json['editionId'] ?? '',
    editionUrl: json['editionUrl'] ?? '',
    fileId: json['fileId'] ?? '',
    downloadLinks: (json['downloadLinks'] as List<dynamic>?)
        ?.map((e) => Map<String, String>.from(e as Map))
        .toList() ?? [],
  );
}

class BookEditionDetails {
  final String editionId;
  final String md5;
  final String adsUrl;
  final String? size;
  final String? extension;
  final String? pages;

  const BookEditionDetails({
    required this.editionId,
    required this.md5,
    required this.adsUrl,
    this.size,
    this.extension,
    this.pages,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

/// Why a book search failed (shown to the user instead of "no results").
class BooksSearchException implements Exception {
  final String message;
  BooksSearchException(this.message);
  @override
  String toString() => message;
}

class BooksService {
  /// Mirrors of the same catalog, tried in order. The one that answers last
  /// is remembered and used for the edition / download steps too.
  static const List<String> _mirrors = [
    'https://libgen.li',
    'https://libgen.bz',
    'https://libgen.gs',
    'https://libgen.la',
    'https://libgen.vg',
  ];
  static String _base = _mirrors.first;

  /// Public so the screen can offer "Open in browser".
  static String searchPageUrl(String query) =>
      '$_base/index.php?req=${Uri.encodeComponent(query)}&curtab=f';

  static final _client = http.Client();

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.5',
  };

  // ── Search ─────────────────────────────────────────────────────────────────
  // Returns only epub files. Throws BooksSearchException with the real
  // reason when no mirror could be read, so "nothing found" really means
  // nothing was found.

  Future<List<BookResult>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final problems = <String>[];
    var anyPageRead = false;
    for (final base in _mirrors) {
      final host = Uri.parse(base).host;
      try {
        final url = Uri.parse(
            '$base/index.php?req=${Uri.encodeComponent(query)}&curtab=f');
        debugPrint('[LibGen] search: $url');
        final response = await _client
            .get(url, headers: _headers)
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          problems.add('$host answered HTTP ${response.statusCode}');
          continue;
        }
        final body = response.body;
        final hasRows = body.contains('edition.php');
        if (!hasRows) {
          final lower = body.toLowerCase();
          final botCheck = lower.contains('just a moment') ||
              lower.contains('ddos-guard') ||
              lower.contains('captcha') ||
              lower.contains('cf-chl') ||
              lower.contains('checking your browser');
          if (botCheck) {
            problems.add('$host showed a bot check');
            continue;
          }
          // A real page with no results at all.
          anyPageRead = true;
          _base = base;
          continue;
        }
        final results = _parseRows(body, base);
        anyPageRead = true;
        if (results.isNotEmpty) {
          _base = base;
          debugPrint('[LibGen] found ${results.length} epub results on $host');
          return results;
        }
        // Rows exist but none is an epub (or the layout changed).
        problems.add('$host had results but no EPUB files');
        _base = base;
      } on TimeoutException {
        problems.add('$host timed out');
      } catch (e) {
        problems.add('$host: $e');
      }
    }
    if (anyPageRead) return []; // a mirror answered: nothing to show
    throw BooksSearchException(problems.join('; '));
  }

  /// Reads the result rows by position of the title cell, so a small layout
  /// change (extra leading column) does not break the parser.
  List<BookResult> _parseRows(String html, String base) {
    final document = hp.parse(html);
    final results = <BookResult>[];
    final seen = <String>{};
    for (final row in document.querySelectorAll('tr')) {
      final tds = row.children.where((c) => c.localName == 'td').toList();
      if (tds.length < 8) continue;
      final ti = tds.indexWhere(
          (td) => td.querySelector('a[href*="edition.php"]') != null);
      if (ti < 0) continue;
      final firstTd = tds[ti];
      final titleLink = firstTd.querySelector('a[href*="edition.php"]')!;
      final title = titleLink.text.trim();
      if (title.isEmpty) continue;

      final editionHref = titleLink.attributes['href'] ?? '';
      final editionId = RegExp(r'id=(\d+)').firstMatch(editionHref)?.group(1);
      if (editionId == null || editionId.isEmpty) continue;

      // Columns after the title cell: author, publisher, year, language,
      // pages, size, extension, mirrors.
      String cell(int k) => ti + k < tds.length ? tds[ti + k].text.trim() : '';
      final author = cell(1);
      final publisher = cell(2);
      final year = cell(3);
      final language = cell(4);
      final pages = cell(5);
      final sizeTd = ti + 6 < tds.length ? tds[ti + 6] : null;
      final size = (sizeTd?.querySelector('a')?.text.trim().isNotEmpty ?? false)
          ? sizeTd!.querySelector('a')!.text.trim()
          : (sizeTd?.text.trim() ?? '');
      var format = cell(7).toLowerCase();
      if (format != 'epub') {
        // Layout shifted: accept an epub marker in any later cell.
        final later = tds.skip(ti + 1).any((td) => td.text.trim().toLowerCase() == 'epub');
        if (!later) continue;
        format = 'epub';
      }
      if (!seen.add(editionId)) continue;

      final series = firstTd.querySelector('b')?.text.trim() ?? '';
      final isbn = firstTd.querySelector('font[color="green"]')?.text.trim() ?? '';
      final fileId = firstTd.querySelector('.badge-secondary')?.text.trim() ?? '';

      final downloadLinks = <Map<String, String>>[];
      for (final a in tds.last.querySelectorAll('a')) {
        final href = a.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        final linkTitle = a.attributes['data-original-title'] ??
            a.querySelector('.badge')?.text.trim() ??
            '';
        downloadLinks.add({'title': linkTitle, 'href': href});
      }

      results.add(BookResult(
        title: title,
        series: series,
        author: author,
        publisher: publisher,
        year: year,
        language: language,
        pages: pages,
        size: size,
        format: format,
        isbn: isbn,
        editionId: editionId,
        editionUrl: '$base/edition.php?id=$editionId',
        fileId: fileId,
        downloadLinks: downloadLinks,
      ));
    }
    return results;
  }

  // ── Edition details → MD5 ──────────────────────────────────────────────────
  // Equivalent to: GET /libgen/edition/:editionId

  Future<BookEditionDetails?> getEditionDetails(String editionId) async {
    try {
      final url = Uri.parse('$_base/edition.php?id=$editionId');
      debugPrint('[LibGen] edition: $url');

      final response = await _client.get(url, headers: _headers);
      if (response.statusCode != 200) return null;

      final document = hp.parse(response.body);

      // Extract MD5 from ads.php?md5=... link
      final adsLink = document
          .querySelector('a[href^="ads.php?md5="]')
          ?.attributes['href'];
      final md5Match = RegExp(r'md5=([a-f0-9]+)').firstMatch(adsLink ?? '');
      final md5 = md5Match?.group(1);
      if (md5 == null || md5.isEmpty) {
        debugPrint('[LibGen] MD5 not found for edition $editionId');
        return null;
      }

      // Extract additional file info from #tablelibgen
      String? size, extension, pages;
      for (final row
          in document.querySelectorAll('table#tablelibgen tr')) {
        final tds = row.querySelectorAll('td');
        if (tds.length < 2) continue;
        final text = tds[1].text;

        final sizeMatch = RegExp(r'Size:\s*([^\n]+)').firstMatch(text);
        if (sizeMatch != null) size = sizeMatch.group(1)?.trim();

        final extMatch = RegExp(r'Extension:\s*(\w+)').firstMatch(text);
        if (extMatch != null) extension = extMatch.group(1)?.trim();

        final pagesMatch = RegExp(r'Pages:\s*(\d+)').firstMatch(text);
        if (pagesMatch != null) pages = pagesMatch.group(1)?.trim();
      }

      debugPrint('[LibGen] MD5: $md5');
      return BookEditionDetails(
        editionId: editionId,
        md5: md5,
        adsUrl: '$_base/ads.php?md5=$md5',
        size: size,
        extension: extension,
        pages: pages,
      );
    } catch (e) {
      debugPrint('[LibGen] edition details error: $e');
      return null;
    }
  }

  // ── Download link from MD5 ─────────────────────────────────────────────────
  // Equivalent to: GET /libgen/download/:md5

  Future<String?> getDownloadUrl(String md5) async {
    try {
      final adsUrl = Uri.parse('$_base/ads.php?md5=$md5');
      debugPrint('[LibGen] ads page: $adsUrl');

      final response = await _client.get(adsUrl, headers: _headers);
      if (response.statusCode != 200) return null;

      final document = hp.parse(response.body);

      // Extract get.php link from #main table
      final getLink = document
          .querySelector('table#main a[href^="get.php"]')
          ?.attributes['href'];

      if (getLink == null || getLink.isEmpty) {
        debugPrint('[LibGen] get.php link not found for md5 $md5');
        return null;
      }

      final fullUrl = '$_base/$getLink';
      debugPrint('[LibGen] download URL: $fullUrl');
      return fullUrl;
    } catch (e) {
      debugPrint('[LibGen] download url error: $e');
      return null;
    }
  }

  // ── Convenience: full resolution in one call ───────────────────────────────
  // editionId → MD5 → download URL

  Future<String?> resolveDownloadUrl(String editionId) async {
    final details = await getEditionDetails(editionId);
    if (details == null) return null;
    return getDownloadUrl(details.md5);
  }
}
