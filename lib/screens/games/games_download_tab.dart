import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../api/game_downloader.dart';
import '../../api/game_library.dart';
import '../../api/game_meta.dart';
import 'games_download_widgets.dart';
import 'games_sites_tab.dart';
import 'saved_sites_store.dart';

/// Download tab (Windows): an in-app browser for legal game sources such as
/// itch.io and archive.org. When a page starts a file download, the app
/// asks for confirmation and downloads it itself (resume, parallel pieces,
/// progress), and adds the game to the Library.
class GamesDownloadTab extends StatefulWidget {
  const GamesDownloadTab({super.key});

  // Separate from the Play tab's list.
  static final SavedSitesStore store =
      SavedSitesStore('games_download_sites', () => [
        SavedSite('itch.io', 'https://itch.io/games'),
        SavedSite('Internet Archive', 'https://archive.org/'),
      ]);

  @override
  State<GamesDownloadTab> createState() => _GamesDownloadTabState();
}

class _GamesDownloadTabState extends State<GamesDownloadTab>
    with AutomaticKeepAliveClientMixin {
  final _mgr = DownloadManager.instance;
  int _view = 0; // 0 = sites, 1 = downloads
  bool _asking = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _mgr.load();
    GameLibrary.instance.load();
  }

  Future<void> _onDownload(
      DownloadStartRequest req, Map<String, String> headers) async {
    if (!mounted || _asking) return;
    _asking = true;
    try {
      final url = req.url.toString();
      var fileName = GameMetaResolver.parseFileName(
          req.contentDisposition, req.suggestedFilename);
      if (fileName.isEmpty) {
        final seg = req.url.pathSegments.where((s) => s.isNotEmpty).toList();
        fileName = seg.isEmpty ? 'download' : Uri.decodeComponent(seg.last);
      }
      var dir = await _mgr.downloadDir();
      if (!mounted) return;

      // Look up the game's real name, picture and description (short wait).
      final sourcePage = headers['Referer'] ?? '';
      final meta = await GameMetaResolver.resolve(
              pageUrl: sourcePage, fileName: fileName)
          .timeout(const Duration(seconds: 8), onTimeout: () => GameMeta.empty);
      if (!mounted) return;
      final niceName = meta.title ?? GameMetaResolver.nameFromFileName(fileName);

      final nameCtrl = TextEditingController(text: niceName);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Download this file?'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(fileName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                      req.contentLength > 0
                          ? fmtBytes(req.contentLength)
                          : 'Size not announced by the site',
                      style: const TextStyle(color: Colors.white60)),
                  const SizedBox(height: 4),
                  Text('From ${req.url.host}',
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Game name (for your Library)'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Save to: $dir',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: () async {
                          final picked =
                              await FilePicker.platform.getDirectoryPath();
                          if (picked != null) {
                            await _mgr.setDownloadDir(picked);
                            setD(() => dir = picked);
                          }
                        },
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Download')),
            ],
          ),
        ),
      );
      final gameName = nameCtrl.text.trim();
      nameCtrl.dispose();
      if (confirmed != true || !mounted) return;

      final task = _mgr.start(
        url: url,
        fileName: fileName,
        dir: dir,
        total: req.contentLength > 0 ? req.contentLength : -1,
        headers: headers,
        sourcePage: sourcePage.isEmpty ? null : sourcePage,
      );
      final lib = await GameLibrary.instance.attachDownload(
          gameName.isEmpty ? niceName : gameName, task.id,
          cover: meta.image, description: meta.description, platform: 'PC');
      task.libraryId = lib.id;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      final c = messenger.showSnackBar(SnackBar(
        content: Text('Downloading ${task.fileName}. It is in your Library too.'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
            label: 'VIEW', onPressed: () => setState(() => _view = 1)),
      ));
      Timer(const Duration(seconds: 5), () {
        try {
          c.close();
        } catch (_) {}
      });
    } finally {
      _asking = false;
    }
  }

  Widget _downloadsList() {
    return ListenableBuilder(
      listenable: _mgr,
      builder: (context, _) {
        if (_mgr.tasks.isEmpty) {
          return const Center(
              child: Text('No downloads yet.',
                  style: TextStyle(color: Colors.white54)));
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final t in _mgr.tasks)
              Card(
                color: Colors.white10,
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(t.fileName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600)),
                          ),
                          if (t.state != DlState.downloading)
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              tooltip: t.state == DlState.downloaded
                                  ? 'Remove from list (keeps the file)'
                                  : 'Remove and delete partial file',
                              color: Colors.white54,
                              onPressed: () => _mgr.remove(t.id),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      DownloadStatusView(task: t),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: ListenableBuilder(
            listenable: _mgr,
            builder: (_, _) {
              final active =
                  _mgr.tasks.where((t) => t.state == DlState.downloading).length;
              return SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(
                      value: 0,
                      icon: Icon(Icons.public, size: 16),
                      label: Text('Sites')),
                  ButtonSegment(
                      value: 1,
                      icon: const Icon(Icons.download, size: 16),
                      label: Text(active > 0
                          ? 'Downloads ($active)'
                          : 'Downloads')),
                ],
                selected: {_view},
                onSelectionChanged: (s) => setState(() => _view = s.first),
              );
            },
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _view,
            children: [
              GamesSitesTab(
                store: GamesDownloadTab.store,
                intro:
                    'Open a site and download from it. Use free and legal sources such as itch.io or archive.org, or any site you have the right to download from. When a page starts a download, the app asks you first.',
                onDownload: _onDownload,
              ),
              _downloadsList(),
            ],
          ),
        ),
      ],
    );
  }
}
