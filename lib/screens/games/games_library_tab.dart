import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../../api/game_downloader.dart';
import '../../api/game_library.dart';
import '../../api/games_service.dart';
import '../../utils/app_theme.dart';
import 'games_download_widgets.dart';

/// Library tab: games you want to play / are playing / played.
/// Stored only on this device.
class GamesLibraryTab extends StatefulWidget {
  const GamesLibraryTab({super.key});

  @override
  State<GamesLibraryTab> createState() => _GamesLibraryTabState();
}

class _GamesLibraryTabState extends State<GamesLibraryTab>
    with AutomaticKeepAliveClientMixin {
  final _lib = GameLibrary.instance;
  PlayStatus? _filter; // null = all

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _lib.load();
    DownloadManager.instance.load();
  }

  void _undoSnack(String text, VoidCallback undo) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final c = messenger.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 5),
      action: SnackBarAction(label: 'UNDO', onPressed: undo),
    ));
    Timer(const Duration(seconds: 5), () {
      try {
        c.close();
      } catch (_) {}
    });
  }

  Future<void> _remove(LibraryGame g) async {
    final i = await _lib.remove(g);
    _undoSnack('Removed ${g.name}', () => _lib.restore(g, i));
  }

  /// Lets the user pick the game's .exe (or shortcut) so Launch works.
  Future<String?> _pickLaunchFile(LibraryGame g) async {
    final task = DownloadManager.instance.byId(g.downloadTaskId);
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose the file that starts ${g.name}',
      type: FileType.custom,
      allowedExtensions: const ['exe', 'lnk', 'bat', 'cmd', 'msi'],
      initialDirectory: task?.dir,
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    await _lib.setLaunchPath(g, path);
    return path;
  }

  /// Starts the game, then moves it to "Playing".
  Future<void> _launch(LibraryGame g) async {
    var path = g.launchPath;
    final task = DownloadManager.instance.byId(g.downloadTaskId);
    if (path == null && task != null && task.state == DlState.downloaded && task.isInstaller) {
      path = task.path;
    }
    path ??= await _pickLaunchFile(g);
    if (path == null) return;
    if (!File(path).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("That file isn't there anymore. Choose the game file again.")));
      await _lib.setLaunchPath(g, null);
      return;
    }
    try {
      final ext = p.extension(path).toLowerCase();
      if (ext == '.exe') {
        await Process.start(path, const [],
            workingDirectory: p.dirname(path), mode: ProcessStartMode.detached);
      } else {
        await launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't start the game: $e")));
      return;
    }
    await _lib.setStatus(g, PlayStatus.playing);
    if (_filter != null && mounted) setState(() => _filter = PlayStatus.playing);
  }

  Future<void> _addByName() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a game'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Game name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final added = await _lib.addManual(name);
    if (added == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That game is already in your Library')));
    }
  }

  Future<void> _search() async {
    final picked = await showDialog<GameInfo>(
      context: context,
      builder: (_) => const _SearchDialog(),
    );
    if (picked == null) return;
    var info = picked;
    if (!info.detailsLoaded && info.id.startsWith('steam:')) {
      try {
        info = await SteamGames.details(info);
      } catch (_) {}
    }
    final added = await _lib.addInfo(info);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(added == null
            ? '${info.name} is already in your Library'
            : 'Added ${info.name}')));
  }

  void _details(LibraryGame g) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF14141C),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(20),
          children: [
            if (g.cover != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                    imageUrl: g.cover!,
                    height: 180,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => const SizedBox(height: 0)),
              ),
            const SizedBox(height: 12),
            Text(g.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                [
                  if (g.platform.isNotEmpty) g.platform,
                  if (g.releaseDate.isNotEmpty) g.releaseDate,
                ].join(' · '),
                style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 12),
            Text(
                g.description.isEmpty ? 'No description.' : g.description,
                style: const TextStyle(color: Colors.white70, height: 1.4)),
          ],
        ),
      ),
    );
  }

  Widget _row(LibraryGame g) {
    final task = DownloadManager.instance.byId(g.downloadTaskId);
    return Card(
      color: Colors.white10,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _details(g),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 96,
                  height: 64,
                  child: g.cover == null
                      ? Container(
                          color: Colors.white12,
                          child: const Icon(Icons.sports_esports,
                              color: Colors.white38))
                      : CachedNetworkImage(
                          imageUrl: g.cover!,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => Container(
                              color: Colors.white12,
                              child: const Icon(Icons.sports_esports,
                                  color: Colors.white38)),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                        [
                          if (g.platform.isNotEmpty) g.platform,
                          if (g.releaseDate.isNotEmpty) g.releaseDate,
                        ].join(' · '),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                    if (g.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(g.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 12)),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        DropdownButton<PlayStatus>(
                          value: g.status,
                          isDense: true,
                          underline: const SizedBox(),
                          dropdownColor: const Color(0xFF1E1E2A),
                          style: TextStyle(
                              color: AppTheme.current.primaryColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                          items: PlayStatus.values
                              .map((s) => DropdownMenuItem(
                                  value: s, child: Text(s.label)))
                              .toList(),
                          onChanged: (s) {
                            if (s != null) _lib.setStatus(g, s);
                          },
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: 'Remove',
                          color: Colors.white54,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _remove(g),
                        ),
                      ],
                    ),
                    if (Platform.isWindows)
                      Row(
                        children: [
                          if (g.launchPath != null ||
                              (task != null &&
                                  task.state == DlState.downloaded &&
                                  task.isInstaller))
                            FilledButton.icon(
                              onPressed: () => _launch(g),
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: const Text('Launch'),
                              style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact),
                            ),
                          PopupMenuButton<String>(
                            tooltip: 'Game file',
                            icon: const Icon(Icons.more_horiz,
                                size: 20, color: Colors.white54),
                            onSelected: (v) {
                              if (v == 'choose') _pickLaunchFile(g);
                              if (v == 'launch') _launch(g);
                            },
                            itemBuilder: (_) => [
                              if (g.launchPath == null)
                                const PopupMenuItem(
                                    value: 'launch',
                                    child: Text('Launch (choose game file)')),
                              PopupMenuItem(
                                  value: 'choose',
                                  child: Text(g.launchPath == null
                                      ? 'Choose game file'
                                      : 'Change game file')),
                            ],
                          ),
                        ],
                      ),
                    if (task != null) ...[
                      const SizedBox(height: 4),
                      DownloadStatusView(task: task),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_lib, DownloadManager.instance]),
      builder: (context, _) {
        final items = _lib.games
            .where((g) => _filter == null || g.status == _filter)
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _chip('All', null),
                          for (final s in PlayStatus.values) _chip(s.label, s),
                        ],
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Add a game',
                    onSelected: (v) => v == 'search' ? _search() : _addByName(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'search', child: Text('Search Steam / IGDB')),
                      PopupMenuItem(value: 'name', child: Text('Add by name')),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _lib.games.isEmpty
                              ? 'Your Library is empty. Tap + to search for a game or add one by name. Games you download show up here too.'
                              : 'No games with this status.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                      children: items.map(_row).toList(),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _chip(String label, PlayStatus? s) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label),
          selected: _filter == s,
          onSelected: (_) => setState(() => _filter = s),
        ),
      );
}

/// Search Steam (and IGDB when keys are saved) and pick a game.
class _SearchDialog extends StatefulWidget {
  const _SearchDialog();

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _ctrl = TextEditingController();
  List<GameInfo> _results = [];
  bool _busy = false;
  String? _note;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _note = null;
      _results = [];
    });
    final notes = <String>[];
    final steam = <GameInfo>[];
    final igdb = <GameInfo>[];
    await Future.wait([
      SteamGames.search(q).then(steam.addAll).catchError((Object e) {
        notes.add('Steam: $e');
      }),
      IgdbGames.hasCredentials().then((has) async {
        if (!has) {
          notes.add('Console games need IGDB keys (Settings > Games).');
          return;
        }
        try {
          igdb.addAll(await IgdbGames.search(q));
        } catch (e) {
          notes.add('IGDB: $e');
        }
      }),
    ]);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _results = [...steam, ...igdb];
      _note = _results.isEmpty
          ? (notes.isEmpty ? 'No games found.' : notes.join('\n'))
          : (notes.isEmpty ? null : notes.join('\n'));
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Search games'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _run(),
              decoration: InputDecoration(
                hintText: 'Game name',
                suffixIcon: IconButton(
                    icon: const Icon(Icons.search), onPressed: _run),
              ),
            ),
            if (_busy)
              const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator()),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_note!,
                    style: const TextStyle(color: Colors.white60, fontSize: 12)),
              ),
            Expanded(
              child: ListView(
                children: _results
                    .map((g) => ListTile(
                          dense: true,
                          leading: g.cover == null
                              ? null
                              : SizedBox(
                                  width: 56,
                                  child: CachedNetworkImage(
                                      imageUrl: g.cover!,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, _, _) =>
                                          const Icon(Icons.sports_esports)),
                                ),
                          title: Text(g.name,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(g.platformLabel),
                          onTap: () => Navigator.pop(context, g),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}
