import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// One saved website (a tile in the Play or Download tab).
class SavedSite {
  String name;
  final String url;
  SavedSite(this.name, this.url);

  Map<String, String> toJson() => {'name': name, 'url': url};

  static SavedSite? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = (j['name'] ?? '').toString();
    final url = (j['url'] ?? '').toString();
    if (name.isEmpty || url.isEmpty) return null;
    return SavedSite(name, url);
  }

  /// Comparable form of a URL: no scheme, no "www.", no trailing slash.
  static String normalize(String url) {
    var u = url.trim().toLowerCase();
    u = u.replaceFirst(RegExp(r'^https?://'), '');
    u = u.replaceFirst(RegExp(r'^www\.'), '');
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}

/// Device-local list of saved sites. Each tab uses its own [key], so the
/// Play list and the Download list never share entries.
class SavedSitesStore {
  final String key;
  final List<SavedSite> Function() defaults;
  SavedSitesStore(this.key, this.defaults);

  Future<List<SavedSite>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return defaults();
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list.map(SavedSite.fromJson).whereType<SavedSite>().toList();
      }
    } catch (_) {}
    return defaults();
  }

  Future<void> save(List<SavedSite> sites) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        key, jsonEncode(sites.map((s) => s.toJson()).toList()));
  }
}
