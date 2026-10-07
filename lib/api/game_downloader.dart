import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DlState { downloading, downloaded, failed }

/// One file download of the Games > Download tab.
class DownloadTask {
  final String id;
  final String url;
  String fileName;
  final String dir;
  int total; // bytes, -1 when the server doesn't say
  int received = 0;
  DlState state = DlState.downloading;
  String? error;
  bool supportsRange = false;
  int pieces = 1;
  double speed = 0; // bytes per second, smoothed
  String? libraryId;

  /// The page the download started on (used for "Open in browser").
  String? sourcePage;

  // Kept in memory only (never written to disk).
  Map<String, String> headers = {};
  String? resolvedUrl;

  DownloadTask({
    required this.id,
    required this.url,
    required this.fileName,
    required this.dir,
    this.total = -1,
  });

  String get path => p.join(dir, fileName);
  String partPath(int i) => '$path.part$i';

  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;

  Duration? get eta {
    if (total <= 0 || speed < 1) return null;
    return Duration(seconds: ((total - received) / speed).ceil());
  }

  bool get isInstaller {
    final e = p.extension(fileName).toLowerCase();
    return e == '.exe' || e == '.msi';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'fileName': fileName,
        'dir': dir,
        'total': total,
        'state': state.name,
        'error': error,
        'supportsRange': supportsRange,
        'pieces': pieces,
        'libraryId': libraryId,
        'sourcePage': sourcePage,
      };

  static DownloadTask? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final t = DownloadTask(
        id: j['id'].toString(),
        url: j['url'].toString(),
        fileName: j['fileName'].toString(),
        dir: j['dir'].toString(),
        total: (j['total'] as num?)?.toInt() ?? -1,
      );
      t.state = DlState.values.firstWhere((s) => s.name == j['state'],
          orElse: () => DlState.failed);
      t.error = j['error']?.toString();
      t.supportsRange = j['supportsRange'] == true;
      t.pieces = (j['pieces'] as num?)?.toInt() ?? 1;
      t.libraryId = j['libraryId']?.toString();
      t.sourcePage = j['sourcePage']?.toString();
      return t;
    } catch (_) {
      return null;
    }
  }
}

class _Ctl {
  bool cancelled = false;
  final clients = <HttpClient>[];
  final pieceBytes = <int, int>{};
  Timer? ticker;
  void abort() {
    cancelled = true;
    ticker?.cancel();
    for (final c in clients) {
      try {
        c.close(force: true);
      } catch (_) {}
    }
  }
}

class _Probe {
  final int total;
  final bool ranges;
  final String finalUrl;
  _Probe(this.total, this.ranges, this.finalUrl);
}

/// Downloads files for the Games section: resumes partial files, uses 4
/// parallel pieces when the server supports ranges, retries by itself,
/// checks the final size, and shows smoothed speed / time left.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  static const _tasksKey = 'games_downloads';
  static const _dirKey = 'games_download_dir';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _maxPieces = 4;
  static const _minPieceableBytes = 8 * 1024 * 1024;
  static const _maxAttempts = 5;

  final List<DownloadTask> tasks = [];
  final Map<String, _Ctl> _ctl = {};
  bool _loaded = false;

  DownloadTask? byId(String? id) {
    if (id == null) return null;
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tasksKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final j in list) {
            final t = DownloadTask.fromJson(j);
            if (t == null) continue;
            if (t.state == DlState.downloading) {
              // The app closed mid-download: keep the partial file, offer Retry.
              t.state = DlState.failed;
              t.error = 'Interrupted. Retry continues where it stopped.';
            }
            t.received = _partsOnDisk(t);
            tasks.add(t);
          }
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _tasksKey, jsonEncode(tasks.map((t) => t.toJson()).toList()));
  }

  int _partsOnDisk(DownloadTask t) {
    var sum = 0;
    for (var i = 0; i < t.pieces; i++) {
      final f = File(t.partPath(i));
      if (f.existsSync()) sum += f.lengthSync();
    }
    return sum;
  }

  // ── Download folder ───────────────────────────────────────────────────

  Future<String> downloadDir() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_dirKey);
    if (saved != null && saved.isNotEmpty) return saved;
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    return p.join(base.path, 'PlayTorrio Games');
  }

  Future<void> setDownloadDir(String dir) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dirKey, dir);
  }

  // ── Public actions ────────────────────────────────────────────────────

  String sanitizeFileName(String name) {
    var n = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    n = n.replaceAll(RegExp(r'[. ]+$'), '');
    return n.isEmpty ? 'download' : n;
  }

  String _uniqueName(String dir, String name) {
    final ext = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    var candidate = name;
    var n = 1;
    bool taken(String c) {
      final full = p.join(dir, c);
      if (File(full).existsSync() || File('$full.part0').existsSync()) {
        return true;
      }
      return tasks.any((t) => t.path == full);
    }

    while (taken(candidate)) {
      candidate = '$stem ($n)$ext';
      n++;
    }
    return candidate;
  }

  DownloadTask start({
    required String url,
    required String fileName,
    required String dir,
    int total = -1,
    Map<String, String> headers = const {},
    String? sourcePage,
  }) {
    final t = DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: url,
      fileName: _uniqueName(dir, sanitizeFileName(fileName)),
      dir: dir,
      total: total,
    )
      ..headers = Map.of(headers)
      ..sourcePage = sourcePage;
    tasks.insert(0, t);
    _persist();
    notifyListeners();
    _run(t);
    return t;
  }

  void retry(String id) {
    final t = byId(id);
    if (t == null || t.state == DlState.downloading) return;
    t.state = DlState.downloading;
    t.error = null;
    notifyListeners();
    _run(t);
  }

  /// Stops a running download. With [deletePartial] the partial files go too.
  Future<void> cancel(String id, {required bool deletePartial}) async {
    final t = byId(id);
    if (t == null) return;
    _ctl[id]?.abort();
    t.state = DlState.failed;
    t.error = 'Cancelled';
    t.speed = 0;
    if (deletePartial) {
      await _deleteParts(t);
      t.received = 0;
    }
    await _persist();
    notifyListeners();
  }

  /// Removes the task from the list (and partial files when not finished).
  /// With [deleteFile] a finished download is deleted from disk too: the
  /// downloaded file.
  Future<void> remove(String id, {bool deleteFile = false}) async {
    final t = byId(id);
    if (t == null) return;
    _ctl[id]?.abort();
    if (t.state != DlState.downloaded) {
      await _deleteParts(t);
    } else if (deleteFile) {
      try {
        final f = File(t.path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    tasks.remove(t);
    await _persist();
    notifyListeners();
  }

  Future<void> _deleteParts(DownloadTask t) async {
    for (var i = 0; i < _maxPieces; i++) {
      try {
        final f = File(t.partPath(i));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  // ── Engine ────────────────────────────────────────────────────────────

  HttpClient _newClient(_Ctl ctl) {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false
      ..userAgent = _ua;
    ctl.clients.add(c);
    return c;
  }

  Map<String, String> _headersFor(DownloadTask t, Uri target) {
    final h = <String, String>{
      'User-Agent': _ua,
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
    };
    final origin = Uri.tryParse(t.url);
    final sameHost = origin != null && origin.host == target.host;
    t.headers.forEach((k, v) {
      // Cookies and referer only go to the site the user was browsing.
      if (!sameHost &&
          (k.toLowerCase() == 'cookie' || k.toLowerCase() == 'authorization')) {
        return;
      }
      h[k] = v;
    });
    return h;
  }

  Future<_Probe> _probe(DownloadTask t, _Ctl ctl) async {
    final client = _newClient(ctl);
    try {
      var uri = Uri.parse(t.url);
      final req = await client.getUrl(uri);
      _headersFor(t, uri).forEach(req.headers.set);
      req.headers.set('Range', 'bytes=0-0');
      final res = await req.close().timeout(const Duration(seconds: 30));
      for (final r in res.redirects) {
        uri = uri.resolveUri(r.location);
      }
      if (res.statusCode == 206) {
        final cr = res.headers.value('content-range') ?? '';
        final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
        final total = m == null ? -1 : int.parse(m.group(1)!);
        return _Probe(total, total > 0, uri.toString());
      }
      if (res.statusCode == 200) {
        return _Probe(res.contentLength, false, uri.toString());
      }
      throw 'The site answered HTTP ${res.statusCode}';
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _run(DownloadTask t) async {
    final ctl = _Ctl();
    _ctl[t.id] = ctl;
    try {
      await Directory(t.dir).create(recursive: true);

      final probe = await _probe(t, ctl);
      if (ctl.cancelled) return;
      if (t.total > 0 && probe.total > 0 && t.total != probe.total) {
        // The file on the server changed: old partial data is useless.
        await _deleteParts(t);
      }
      t.total = probe.total;
      t.supportsRange = probe.ranges;
      t.resolvedUrl = probe.finalUrl;

      final pieceCount =
          (t.supportsRange && t.total >= _minPieceableBytes) ? _maxPieces : 1;
      if (pieceCount != t.pieces) {
        await _deleteParts(t); // layout changed, start clean
      }
      t.pieces = pieceCount;

      // Piece ranges (inclusive). Unknown size => one open-ended piece.
      final ranges = <(int, int)>[];
      if (t.total > 0) {
        final size = (t.total / pieceCount).ceil();
        for (var i = 0; i < pieceCount; i++) {
          final s = i * size;
          final e = (s + size - 1).clamp(0, t.total - 1);
          if (s <= e) ranges.add((s, e));
        }
      } else {
        ranges.add((0, -1));
      }

      for (var i = 0; i < ranges.length; i++) {
        final f = File(t.partPath(i));
        var have = f.existsSync() ? f.lengthSync() : 0;
        final want = ranges[i].$2 < 0 ? -1 : ranges[i].$2 - ranges[i].$1 + 1;
        if (!t.supportsRange || (want > 0 && have > want)) {
          if (f.existsSync()) await f.delete();
          have = 0;
        }
        ctl.pieceBytes[i] = have;
      }
      t.received = ctl.pieceBytes.values.fold(0, (a, b) => a + b);

      var lastReceived = t.received;
      t.speed = 0;
      ctl.ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        final now = ctl.pieceBytes.values.fold<int>(0, (a, b) => a + b);
        final inst = (now - lastReceived).toDouble();
        lastReceived = now;
        t.received = now;
        t.speed = t.speed == 0 ? inst : t.speed * 0.7 + inst * 0.3;
        notifyListeners();
      });
      notifyListeners();

      await Future.wait([
        for (var i = 0; i < ranges.length; i++)
          _piece(t, ctl, i, ranges[i].$1, ranges[i].$2),
      ]);
      ctl.ticker?.cancel();
      if (ctl.cancelled) return;

      // Check every piece, then join them into the final file.
      for (var i = 0; i < ranges.length; i++) {
        final want = ranges[i].$2 < 0 ? -1 : ranges[i].$2 - ranges[i].$1 + 1;
        final got = await File(t.partPath(i)).length();
        if (want > 0 && got != want) {
          throw 'Piece ${i + 1} is incomplete ($got of $want bytes)';
        }
      }
      final out = File(t.path);
      if (await out.exists()) await out.delete();
      final sink = out.openWrite();
      try {
        for (var i = 0; i < ranges.length; i++) {
          await sink.addStream(File(t.partPath(i)).openRead());
        }
      } finally {
        await sink.close();
      }
      final finalSize = await out.length();
      if (t.total > 0 && finalSize != t.total) {
        await out.delete();
        await _deleteParts(t);
        throw 'Size check failed ($finalSize of ${t.total} bytes). '
            'Retry will download it again.';
      }
      await _deleteParts(t);
      await _fixExtension(t);
      t.received = finalSize;
      if (t.total <= 0) t.total = finalSize;
      t.state = DlState.downloaded;
      t.error = null;
      t.speed = 0;
    } catch (e) {
      ctl.ticker?.cancel();
      if (ctl.cancelled) return;
      t.state = DlState.failed;
      t.error = _friendly(e);
      t.speed = 0;
      t.received = _partsOnDisk(t);
      if (kDebugMode) debugPrint('[GameDownload] ${t.fileName}: $e');
    } finally {
      for (final c in ctl.clients) {
        try {
          c.close(force: true);
        } catch (_) {}
      }
      if (_ctl[t.id] == ctl) _ctl.remove(t.id);
      await _persist();
      notifyListeners();
    }
  }

  /// Some sites send a file with no extension in its name. Look at the first
  /// bytes and add the right one (only the name changes, nothing is run).
  Future<void> _fixExtension(DownloadTask t) async {
    try {
      if (p.extension(t.fileName).isNotEmpty) return;
      final raf = await File(t.path).open();
      List<int> head;
      try {
        head = await raf.read(8);
      } finally {
        await raf.close();
      }
      String? ext;
      if (head.length >= 4 && head[0] == 0x50 && head[1] == 0x4B) {
        ext = '.zip';
      } else if (head.length >= 2 && head[0] == 0x4D && head[1] == 0x5A) {
        ext = '.exe';
      } else if (head.length >= 4 &&
          head[0] == 0x37 && head[1] == 0x7A && head[2] == 0xBC && head[3] == 0xAF) {
        ext = '.7z';
      } else if (head.length >= 4 &&
          head[0] == 0x52 && head[1] == 0x61 && head[2] == 0x72 && head[3] == 0x21) {
        ext = '.rar';
      }
      if (ext == null) return;
      final newName = _uniqueName(t.dir, '${t.fileName}$ext');
      await File(t.path).rename(p.join(t.dir, newName));
      t.fileName = newName;
    } catch (_) {}
  }

  String _friendly(Object e) {
    if (e is TimeoutException) return 'The server stopped answering';
    if (e is SocketException) return 'Connection problem: ${e.message}';
    if (e is FileSystemException) {
      return 'Could not write the file: ${e.message}';
    }
    return e.toString();
  }

  /// Downloads one piece into its own part file, resuming from what is
  /// already there and retrying a few times with a growing pause.
  Future<void> _piece(
      DownloadTask t, _Ctl ctl, int i, int start, int end) async {
    final part = File(t.partPath(i));
    final want = end < 0 ? -1 : end - start + 1;
    var attempt = 0;
    while (true) {
      if (ctl.cancelled) return;
      var have = part.existsSync() ? part.lengthSync() : 0;
      if (want > 0 && have >= want) return;
      try {
        final target = Uri.parse(t.resolvedUrl ?? t.url);
        final client = _newClient(ctl);
        final req = await client.getUrl(target);
        _headersFor(t, target).forEach(req.headers.set);
        final ranged = t.supportsRange && want > 0;
        if (ranged) {
          req.headers.set('Range', 'bytes=${start + have}-$end');
        } else if (have > 0) {
          await part.delete(); // server can't resume: start over
          have = 0;
          ctl.pieceBytes[i] = 0;
        }
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (ranged) {
          if (res.statusCode == 200 && t.pieces == 1 && have == 0) {
            // Server sent the whole file; fine for a single piece.
          } else if (res.statusCode != 206) {
            await res.drain<void>();
            throw 'The server did not honour the range request '
                '(HTTP ${res.statusCode})';
          }
        } else if (res.statusCode != 200) {
          await res.drain<void>();
          throw 'The site answered HTTP ${res.statusCode}';
        }
        final sink = part.openWrite(
            mode: have > 0 && ranged ? FileMode.append : FileMode.write);
        try {
          await for (final chunk
              in res.timeout(const Duration(seconds: 30))) {
            if (ctl.cancelled) break;
            sink.add(chunk);
            ctl.pieceBytes[i] = (ctl.pieceBytes[i] ?? 0) + chunk.length;
            attempt = 0;
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (ctl.cancelled) return;
        if (want < 0) return; // unknown size: the stream ending is the end
        final now = part.existsSync() ? part.lengthSync() : 0;
        if (now <= have && (want < 0 || now < want)) {
          // Connection ended without any data: count it as a failed try.
          throw 'The server closed the connection without sending data';
        }
      } catch (e) {
        if (ctl.cancelled) return;
        attempt++;
        if (attempt >= _maxAttempts) rethrow;
        // Re-sync the counter with what actually reached the disk.
        ctl.pieceBytes[i] = part.existsSync() ? part.lengthSync() : 0;
        await Future.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }
}
