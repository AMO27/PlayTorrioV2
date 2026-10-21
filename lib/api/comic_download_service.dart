import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'comic_page_extractor.dart';
import 'comics_service.dart';
import 'extra_comic_sources.dart';

/// One finished download shown in the Comics > Downloads list.
class DownloadedComic {
  final String title; // series / comic title
  final String chapter; // issue title or file name
  final String path; // folder of page images, or a single file
  final bool isFolder;
  final int pages;
  final Comic? comic;

  DownloadedComic({
    required this.title,
    required this.chapter,
    required this.path,
    required this.isFolder,
    required this.pages,
    this.comic,
  });
}

/// Saves comics inside the app: page images (one folder per issue, readable
/// offline) for BatCave / Read Free Comics, and the file itself for GetComics.
class ComicDownloadService {
  ComicDownloadService._();
  static final ComicDownloadService instance = ComicDownloadService._();

  /// key (chapter url) -> progress 0..1 (-1 = failed). Present while active.
  final ValueNotifier<Map<String, double>> progress =
      ValueNotifier<Map<String, double>>({});

  /// Last error text per key, shown by the UI.
  final Map<String, String> errors = {};

  void _set(String key, double v) {
    progress.value = {...progress.value, key: v};
  }

  void _clear(String key) {
    final m = {...progress.value};
    m.remove(key);
    progress.value = m;
  }

  static String _safe(String s) {
    final t = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    final out = t.isEmpty ? 'comic' : t;
    return out.length > 80 ? out.substring(0, 80).trim() : out;
  }

  static Future<Directory> root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'PlayTorrio', 'Comics'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// BatCave / Read Free Comics issues can all be downloaded; on GetComics only
  /// the direct "DOWNLOAD NOW" button (the mirrors open in the browser).
  static bool canDownload(Comic comic, ComicChapter chapter) {
    if (_isGetComics(comic)) {
      return chapter.title.toUpperCase().contains('DOWNLOAD NOW');
    }
    return true;
  }

  static bool _isGetComics(Comic c) =>
      c.source == GetComicsScraper.sourceTag || GetComicsScraper.ownsUrl(c.url);

  bool isActive(String key) => progress.value.containsKey(key);

  /// Starts a download. Returns null on success or a short error message.
  Future<String?> download(Comic comic, ComicChapter chapter) async {
    final key = chapter.url;
    if (isActive(key)) return null;
    errors.remove(key);
    _set(key, 0);
    try {
      if (_isGetComics(comic)) {
        await _downloadFile(comic, chapter, key);
      } else {
        await _downloadPages(comic, chapter, key);
      }
      _clear(key);
      return null;
    } catch (e) {
      debugPrint('[ComicDownload] failed: $e');
      final msg = e is ComicsUnavailableException ? e.message : '$e';
      errors[key] = msg;
      _clear(key);
      return msg;
    }
  }

  Future<void> _downloadPages(Comic comic, ComicChapter chapter, String key) async {
    final extractor = ComicPageExtractor();
    final List<String> pages;
    try {
      pages = await ComicsService().getChapterPages(chapter.url, extractor);
    } finally {
      extractor.dispose();
    }
    if (pages.isEmpty) throw Exception('No pages found for this issue.');

    final base = await root();
    final dir = Directory(p.join(base.path, _safe(comic.title), _safe(chapter.title)));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    var done = 0;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= pages.length) return;
        Exception? last;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            final res = await http.get(Uri.parse(pages[i])).timeout(const Duration(seconds: 40));
            if (res.statusCode == 200 && res.bodyBytes.length > 500) {
              final ct = res.headers['content-type'] ?? '';
              final ext = ct.contains('png')
                  ? 'png'
                  : ct.contains('jpeg') || ct.contains('jpg')
                      ? 'jpg'
                      : 'webp';
              await File(p.join(dir.path, '${(i + 1).toString().padLeft(4, '0')}.$ext'))
                  .writeAsBytes(res.bodyBytes);
              last = null;
              break;
            }
            last = Exception('page ${i + 1}: HTTP ${res.statusCode}');
          } catch (e) {
            last = Exception('page ${i + 1}: $e');
          }
          await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        }
        if (last != null) throw last;
        done++;
        _set(key, done / pages.length);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));

    await File(p.join(dir.path, 'meta.json')).writeAsString(jsonEncode({
      'comic': comic.toJson(),
      'chapter': chapter.title,
      'pages': pages.length,
    }));
  }

  Future<void> _downloadFile(Comic comic, ComicChapter chapter, String key) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(chapter.url))
        ..followRedirects = true
        ..maxRedirects = 8
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw Exception('The download host answered HTTP ${res.statusCode}.');
      }
      final ct = (res.headers['content-type'] ?? '').toLowerCase();
      if (ct.contains('text/html')) {
        throw Exception(
            'This download needs a browser step (the host showed a web page instead of the file). Tap the row to open it in your browser instead.');
      }

      var name = '';
      final cd = res.headers['content-disposition'] ?? '';
      final m = RegExp(r'''filename\*?=(?:UTF-8'')?["']?([^";]+)''', caseSensitive: false)
          .firstMatch(cd);
      if (m != null) name = Uri.decodeComponent(m.group(1)!.trim());
      if (name.isEmpty) {
        final last = res.request?.url.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
        name = Uri.decodeComponent(last);
      }
      if (name.isEmpty || !name.contains('.')) name = '${_safe(comic.title)}.cbz';

      final base = await root();
      final dir = Directory(p.join(base.path, _safe(comic.title)));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, _safe(name)));
      final sink = file.openWrite();
      final total = res.contentLength ?? 0;
      var got = 0;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) _set(key, got / total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (got < 10000) {
        await file.delete();
        throw Exception('The download came back empty.');
      }
    } finally {
      client.close();
    }
  }

  /// Everything saved so far.
  Future<List<DownloadedComic>> list() async {
    final out = <DownloadedComic>[];
    final base = await root();
    await for (final series in base.list()) {
      if (series is! Directory) continue;
      final seriesName = p.basename(series.path);
      await for (final item in series.list()) {
        if (item is Directory) {
          final metaFile = File(p.join(item.path, 'meta.json'));
          if (!await metaFile.exists()) continue;
          try {
            final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
            final comic = Comic.fromJson(Map<String, dynamic>.from(meta['comic'] as Map));
            out.add(DownloadedComic(
              title: comic.title,
              chapter: meta['chapter']?.toString() ?? p.basename(item.path),
              path: item.path,
              isFolder: true,
              pages: (meta['pages'] as num?)?.toInt() ?? 0,
              comic: comic,
            ));
          } catch (_) {}
        } else if (item is File) {
          out.add(DownloadedComic(
            title: seriesName,
            chapter: p.basename(item.path),
            path: item.path,
            isFolder: false,
            pages: 0,
          ));
        }
      }
    }
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }

  Future<void> delete(DownloadedComic d) async {
    try {
      if (d.isFolder) {
        await Directory(d.path).delete(recursive: true);
      } else {
        await File(d.path).delete();
      }
      final parent = Directory(p.dirname(d.path));
      if (await parent.exists() && (await parent.list().isEmpty)) {
        await parent.delete();
      }
    } catch (e) {
      debugPrint('[ComicDownload] delete failed: $e');
    }
  }

  /// Sorted page image paths for a downloaded folder.
  static Future<List<String>> localPages(String dir) async {
    final files = await Directory(dir)
        .list()
        .where((e) => e is File && !e.path.endsWith('meta.json'))
        .map((e) => e.path)
        .toList();
    files.sort();
    return files;
  }
}
