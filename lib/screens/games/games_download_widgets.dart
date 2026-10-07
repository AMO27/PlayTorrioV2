import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../../api/game_downloader.dart';
import '../../api/game_library.dart';

String fmtBytes(num b) {
  if (b < 0) return '?';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${u[i]}';
}

String fmtEta(Duration? d) {
  if (d == null) return '';
  if (d.inSeconds < 60) return '${d.inSeconds}s left';
  if (d.inMinutes < 60) return '${d.inMinutes} min left';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return '${h}h ${m}m left';
}

Future<void> openDownloadFolder(DownloadTask t) async {
  try {
    await launchUrl(Uri.directory(t.dir), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Sends the user to the page in their normal browser, where the site's own
/// download works with their sign-in.
Future<void> openInBrowser(BuildContext context, DownloadTask t) async {
  final target = t.sourcePage ?? t.url;
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  final c = m.showSnackBar(const SnackBar(
      content: Text('Sending you to your browser…'),
      duration: Duration(seconds: 3)));
  Timer(const Duration(seconds: 3), () {
    try {
      c.close();
    } catch (_) {}
  });
  try {
    await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Opens an archive (.zip / .7z / .rar) with the app Windows uses for it,
/// such as WinRAR or 7-Zip.
Future<void> openArchive(DownloadTask t) async {
  try {
    await launchUrl(Uri.file(t.path), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

bool isArchiveName(String name) => const {'.zip', '.7z', '.rar'}
    .contains(p.extension(name).toLowerCase());

Future<void> launchDownloaded(DownloadTask t) async {
  try {
    await launchUrl(Uri.file(t.path), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Deletes the downloaded file after a confirmation. Anything you unpacked
/// yourself, or installed, is not touched: delete that folder yourself, or
/// uninstall the game from Windows Settings > Apps.
Future<bool> confirmDeleteDownload(BuildContext context, DownloadTask t) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete the downloaded file?'),
      content: Text('${t.path}\n\nThis permanently deletes the file only. A '
          'folder you unpacked from it, or a game you installed with it, stays '
          'where it is (uninstall installed games in Windows Settings > Apps).'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete file')),
      ],
    ),
  );
  if (ok != true) return false;
  final mgr = DownloadManager.instance;
  for (final g in GameLibrary.instance.games) {
    if (g.launchPath != null && g.launchPath == t.path) {
      await GameLibrary.instance.setLaunchPath(g, null);
    }
  }
  await mgr.remove(t.id, deleteFile: true);
  return true;
}

/// Asks what to do with the partial file when a download is cancelled.
Future<void> askCancel(BuildContext context, DownloadTask t) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Stop this download?'),
      content: Text(
          '${t.fileName}\n\nKeep the part that is already downloaded so you can continue later, or delete it?'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Keep downloading')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('Stop, keep file')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('Stop, delete file')),
      ],
    ),
  );
  if (choice == null) return;
  await DownloadManager.instance.cancel(t.id, deletePartial: choice == 'delete');
}

/// Progress / result of a download: used in the Library and the Download tab.
class DownloadStatusView extends StatelessWidget {
  final DownloadTask task;
  final bool showCancel;
  const DownloadStatusView(
      {super.key, required this.task, this.showCancel = true});

  @override
  Widget build(BuildContext context) {
    final t = task;
    switch (t.state) {
      case DlState.downloading:
        final pct = t.fraction;
        final bits = <String>[
          if (pct != null) '${(pct * 100).toStringAsFixed(0)}%'
          else
            fmtBytes(t.received),
          if (t.speed > 0) '${fmtBytes(t.speed)}/s',
          if (fmtEta(t.eta).isNotEmpty) fmtEta(t.eta),
          if (t.total > 0) '${fmtBytes(t.received)} of ${fmtBytes(t.total)}',
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _chip('Downloading', Colors.blueAccent),
              const Spacer(),
              if (showCancel)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Stop',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => askCancel(context, t),
                ),
            ]),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: pct, minHeight: 4),
            const SizedBox(height: 4),
            Text(bits.join(' · '),
                style: const TextStyle(color: Colors.white60, fontSize: 11)),
          ],
        );
      case DlState.downloaded:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _chip('Downloaded', Colors.greenAccent.shade400),
                Text(fmtBytes(t.total),
                    style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                if (Platform.isWindows)
                  TextButton.icon(
                    onPressed: () => openDownloadFolder(t),
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('Open folder'),
                  ),
                if (Platform.isWindows && isArchiveName(t.fileName))
                  TextButton.icon(
                    onPressed: () => openArchive(t),
                    icon: const Icon(Icons.unarchive_outlined, size: 16),
                    label: const Text('Open archive'),
                  ),
                if (Platform.isWindows)
                  TextButton.icon(
                    onPressed: () => confirmDeleteDownload(context, t),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete file'),
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.redAccent),
                  ),
                if (Platform.isWindows && t.isInstaller)
                  TextButton.icon(
                    onPressed: () => launchDownloaded(t),
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label:
                        Text('Launch ${p.extension(t.fileName).toLowerCase()}'),
                  ),
              ],
            ),
          ],
        );
      case DlState.failed:
        final cancelled = t.error == 'Cancelled';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _chip(cancelled ? 'Cancelled' : 'Failed',
                  cancelled ? Colors.orangeAccent : Colors.redAccent),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => DownloadManager.instance.retry(t.id),
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(t.received > 0 ? 'Retry (resume)' : 'Retry'),
              ),
              if (!cancelled)
                TextButton.icon(
                  onPressed: () => openInBrowser(context, t),
                  icon: const Icon(Icons.open_in_browser, size: 16),
                  label: const Text('Download in browser'),
                ),
            ]),
            if (!cancelled && (t.error ?? '').isNotEmpty)
              Text(t.error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ],
        );
    }
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      );
}
