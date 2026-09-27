// Parses XMLTV (the standard TV-guide file format most IPTV providers
// publish alongside an M3U playlist) and answers "what's on now / next" for
// a channel. Xtream-Codes portals already get this from their own
// `get_short_epg` API endpoint (see iptv_network.dart) — this service is
// for M3U playlists, which have no such endpoint and otherwise show no
// guide data at all.
import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class EpgProgramme {
  final DateTime start;
  final DateTime end;
  final String title;
  final String? subtitle;

  const EpgProgramme({
    required this.start,
    required this.end,
    required this.title,
    this.subtitle,
  });

  bool get isNow {
    final now = DateTime.now();
    return !now.isBefore(start) && now.isBefore(end);
  }
}

/// Parsed once per XMLTV source and cached in memory for the app session,
/// keyed by the feed's URL so several playlists can each have their own.
class XmltvEpgService {
  XmltvEpgService._();
  static final XmltvEpgService instance = XmltvEpgService._();

  final Map<String, _EpgIndex> _byUrl = {};
  final Map<String, DateTime> _loadedAt = {};

  static const _maxAge = Duration(hours: 6);

  bool isFreshFor(String url) {
    final t = _loadedAt[url];
    return t != null && DateTime.now().difference(t) < _maxAge;
  }

  /// Downloads and parses [url] (plain or gzipped XMLTV). Cheap to call
  /// repeatedly — it's a no-op once cached and still fresh.
  Future<bool> load(String url) async {
    if (isFreshFor(url) && _byUrl.containsKey(url)) return true;
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 25));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return false;
      // Parsing a full guide can be a few MB of XML — do it off the UI
      // isolate so a slow feed doesn't freeze the app while it loads.
      final index = await compute(_parseXmltv, Uint8List.fromList(res.bodyBytes));
      if (index == null) return false;
      _byUrl[url] = index;
      _loadedAt[url] = DateTime.now();
      return true;
    } catch (e) {
      debugPrint('XmltvEpgService: failed to load $url: $e');
      return false;
    }
  }

  static String normalize(String s) =>
      s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), '').replaceAll(RegExp(r'[^a-z0-9._:-]'), '');

  /// All programmes for the channel matching [tvgId] or, failing that,
  /// [channelName], sorted by start time.
  List<EpgProgramme> programmesFor(String url, {String? tvgId, String? channelName}) {
    final index = _byUrl[url];
    if (index == null) return const [];
    for (final key in [tvgId, channelName]) {
      if (key == null || key.trim().isEmpty) continue;
      final list = index.byChannelKey[normalize(key)];
      if (list != null && list.isNotEmpty) return list;
    }
    return const [];
  }

  /// The programme airing right now, if any.
  EpgProgramme? nowFor(String url, {String? tvgId, String? channelName}) {
    final now = DateTime.now();
    for (final p in programmesFor(url, tvgId: tvgId, channelName: channelName)) {
      if (!now.isBefore(p.start) && now.isBefore(p.end)) return p;
    }
    return null;
  }
}

class _EpgIndex {
  final Map<String, List<EpgProgramme>> byChannelKey;
  const _EpgIndex(this.byChannelKey);
}

/// Runs in a background isolate via [compute] — must be a top-level/static
/// function and must not touch [XmltvEpgService.instance].
_EpgIndex? _parseXmltv(Uint8List bytes) {
  try {
    String body;
    if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      body = utf8.decode(GZipDecoder().decodeBytes(bytes));
    } else {
      body = utf8.decode(bytes, allowMalformed: true);
    }
    final doc = XmlDocument.parse(body);

    // channel id -> normalized keys it can be looked up by (its raw id, plus
    // each <display-name>), so a playlist's tvg-id or plain channel name
    // both have a chance of matching.
    final idToKeys = <String, Set<String>>{};
    for (final el in doc.findAllElements('channel')) {
      final id = el.getAttribute('id');
      if (id == null || id.isEmpty) continue;
      final keys = idToKeys.putIfAbsent(id, () => {});
      keys.add(XmltvEpgService.normalize(id));
      for (final dn in el.findElements('display-name')) {
        final t = dn.innerText.trim();
        if (t.isNotEmpty) keys.add(XmltvEpgService.normalize(t));
      }
    }

    final byChannelKey = <String, List<EpgProgramme>>{};
    for (final prog in doc.findAllElements('programme')) {
      final chId = prog.getAttribute('channel');
      if (chId == null || chId.isEmpty) continue;
      final start = _parseXmltvTime(prog.getAttribute('start'));
      if (start == null) continue;
      final end = _parseXmltvTime(prog.getAttribute('stop')) ??
          start.add(const Duration(hours: 1));
      final title = prog.findElements('title').firstOrNull?.innerText.trim() ?? '';
      if (title.isEmpty) continue;
      final sub = prog.findElements('sub-title').firstOrNull?.innerText.trim();

      final programme = EpgProgramme(start: start, end: end, title: title, subtitle: sub);
      final keys = idToKeys[chId] ?? {XmltvEpgService.normalize(chId)};
      for (final key in keys) {
        byChannelKey.putIfAbsent(key, () => []).add(programme);
      }
    }
    for (final list in byChannelKey.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    if (byChannelKey.isEmpty) return null;
    return _EpgIndex(byChannelKey);
  } catch (e) {
    return null;
  }
}

/// XMLTV datetimes look like `YYYYMMDDHHmmss` with an optional ` +0200` zone.
DateTime? _parseXmltvTime(String? raw) {
  if (raw == null || raw.length < 14) return null;
  final spaceIdx = raw.indexOf(' ');
  final core = spaceIdx >= 0 ? raw.substring(0, spaceIdx) : raw.substring(0, 14);
  if (core.length < 14) return null;
  try {
    final y = int.parse(core.substring(0, 4));
    final mo = int.parse(core.substring(4, 6));
    final d = int.parse(core.substring(6, 8));
    final h = int.parse(core.substring(8, 10));
    final mi = int.parse(core.substring(10, 12));
    final sec = int.parse(core.substring(12, 14));
    if (spaceIdx > 0 && raw.length >= spaceIdx + 6) {
      final tz = raw.substring(spaceIdx + 1).trim();
      if (tz.length >= 5 && (tz.startsWith('+') || tz.startsWith('-'))) {
        final sign = tz.startsWith('-') ? -1 : 1;
        final th = int.tryParse(tz.substring(1, 3)) ?? 0;
        final tmi = int.tryParse(tz.substring(3, 5)) ?? 0;
        final utc = DateTime.utc(y, mo, d, h, mi, sec)
            .subtract(Duration(hours: sign * th, minutes: sign * tmi));
        return utc.toLocal();
      }
    }
    return DateTime(y, mo, d, h, mi, sec);
  } catch (_) {
    return null;
  }
}
