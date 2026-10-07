import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'games_service.dart';

enum PlayStatus { want, playing, played }

extension PlayStatusLabel on PlayStatus {
  String get label => switch (this) {
        PlayStatus.want => 'Want to play',
        PlayStatus.playing => 'Playing',
        PlayStatus.played => 'Played',
      };
}

/// One game in the Library. Stored only on this device.
class LibraryGame {
  final String id;
  String name;
  String? cover;
  String platform;
  String releaseDate;
  String description;
  PlayStatus status;
  String? downloadTaskId;
  String? launchPath; // the game's .exe (Windows), chosen by the user

  LibraryGame({
    required this.id,
    required this.name,
    this.cover,
    this.platform = '',
    this.releaseDate = '',
    this.description = '',
    this.status = PlayStatus.want,
    this.downloadTaskId,
    this.launchPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cover': cover,
        'platform': platform,
        'releaseDate': releaseDate,
        'description': description,
        'status': status.name,
        'downloadTaskId': downloadTaskId,
        'launchPath': launchPath,
      };

  static LibraryGame? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = (j['name'] ?? '').toString();
    if (name.isEmpty) return null;
    return LibraryGame(
      id: (j['id'] ?? DateTime.now().microsecondsSinceEpoch).toString(),
      name: name,
      cover: j['cover']?.toString(),
      platform: (j['platform'] ?? '').toString(),
      releaseDate: (j['releaseDate'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      status: PlayStatus.values.firstWhere((s) => s.name == j['status'],
          orElse: () => PlayStatus.want),
      downloadTaskId: j['downloadTaskId']?.toString(),
      launchPath: j['launchPath']?.toString(),
    );
  }
}

class GameLibrary extends ChangeNotifier {
  GameLibrary._();
  static final GameLibrary instance = GameLibrary._();
  static const _key = 'games_library';

  final List<LibraryGame> games = [];
  bool _loaded = false;

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          games.addAll(list.map(LibraryGame.fromJson).whereType<LibraryGame>());
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(games.map((g) => g.toJson()).toList()));
    notifyListeners();
  }

  LibraryGame? findByName(String name) {
    final n = _norm(name);
    if (n.isEmpty) return null;
    for (final g in games) {
      if (_norm(g.name) == n) return g;
    }
    return null;
  }

  bool contains(String name) => findByName(name) != null;

  /// Adds a game from Upcoming / search. Returns null if already present.
  Future<LibraryGame?> addInfo(GameInfo g,
      {PlayStatus status = PlayStatus.want}) async {
    if (contains(g.name)) return null;
    final lg = LibraryGame(
      id: g.id,
      name: g.name,
      cover: g.cover,
      platform: g.platformLabel,
      releaseDate: g.releaseDate,
      description: g.description,
      status: status,
    );
    games.insert(0, lg);
    await _save();
    return lg;
  }

  /// Adds a game by name only.
  Future<LibraryGame?> addManual(String name) async {
    final n = name.trim();
    if (n.isEmpty || contains(n)) return null;
    final lg = LibraryGame(
        id: 'manual:${DateTime.now().microsecondsSinceEpoch}', name: n);
    games.insert(0, lg);
    await _save();
    return lg;
  }

  /// A download was started for [name]: reuse the entry if the game is
  /// already in the Library, otherwise add it as "Want to play".
  Future<LibraryGame> attachDownload(String name, String taskId,
      {String? cover, String? description, String? platform}) async {
    var g = findByName(name);
    if (g == null) {
      g = LibraryGame(
          id: 'manual:${DateTime.now().microsecondsSinceEpoch}',
          name: name.trim());
      games.insert(0, g);
    }
    // Fill in only what is missing; never overwrite what is already there.
    if ((g.cover ?? '').isEmpty && (cover ?? '').isNotEmpty) g.cover = cover;
    if (g.description.isEmpty && (description ?? '').isNotEmpty) {
      g.description = description!;
    }
    if (g.platform.isEmpty && (platform ?? '').isNotEmpty) g.platform = platform!;
    g.downloadTaskId = taskId;
    await _save();
    return g;
  }

  Future<void> setLaunchPath(LibraryGame g, String? path) async {
    g.launchPath = path;
    await _save();
  }

  Future<void> setStatus(LibraryGame g, PlayStatus s) async {
    g.status = s;
    await _save();
  }

  /// Removes a game; returns its position so it can be restored by Undo.
  Future<int> remove(LibraryGame g) async {
    final i = games.indexOf(g);
    if (i >= 0) games.removeAt(i);
    await _save();
    return i;
  }

  Future<void> restore(LibraryGame g, int index) async {
    if (games.contains(g)) return;
    games.insert(index.clamp(0, games.length), g);
    await _save();
  }
}
