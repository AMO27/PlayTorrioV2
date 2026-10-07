import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Safe zip extraction for downloaded games.
///
/// Nothing is ever run here: files are only written to disk. To keep a
/// hostile zip from doing harm, extraction refuses:
///   * paths that climb out of the target folder ("../", absolute paths,
///     drive letters, ":" streams) and Windows device names (CON, NUL, ...),
///   * archives with more than [maxEntries] entries or more than
///     [maxTotalBytes] of data (zip bombs).
/// Symbolic links inside the zip are skipped. Executable-type files get the
/// Windows "downloaded from the internet" mark (Zone.Identifier) so that
/// SmartScreen still asks before they run, as it does for files extracted
/// by Explorer.
const int maxEntries = 100000;
const int maxTotalBytes = 100 * 1024 * 1024 * 1024; // 100 GB

const _reserved = {
  'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5',
  'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5',
  'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

const _markedExts = {
  '.exe', '.dll', '.msi', '.bat', '.cmd', '.com', '.scr', '.lnk', '.ps1',
  '.vbs', '.vbe', '.js', '.jse', '.wsf', '.hta', '.jar', '.reg', '.cpl',
};

/// Extracts [zipPath] into [destDir] (which must not exist yet) in a
/// background isolate. Returns the number of files written. Throws a
/// readable message on failure; the caller removes [destDir] then.
Future<int> extractZipSafely(String zipPath, String destDir) =>
    Isolate.run(() => _extract(zipPath, destDir));

int _extract(String zipPath, String destDir) {
  try {
    return _extractInner(zipPath, destDir);
  } on String {
    rethrow;
  } catch (e) {
    // Only plain strings travel safely out of an isolate.
    throw 'Could not read the zip ($e)';
  }
}

/// Returns the clean path parts of an entry name, null for entries that
/// should simply be skipped, and throws for unsafe names.
List<String>? _safeParts(String name) {
  final n = name.replaceAll('\\', '/');
  if (n.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(n)) {
    throw 'The zip contains an unsafe path ($name)';
  }
  final parts = n.split('/').where((s) => s.isNotEmpty && s != '.').toList();
  if (parts.isEmpty) return null;
  for (final seg in parts) {
    if (seg == '..' ||
        seg.contains(':') ||
        RegExp(r'[<>"|?*\x00-\x1f]').hasMatch(seg) ||
        seg.endsWith('.') ||
        seg.endsWith(' ') ||
        _reserved.contains(seg.split('.').first.toUpperCase())) {
      throw 'The zip contains an unsafe path ($name)';
    }
  }
  return parts;
}

int _extractInner(String zipPath, String destDir) {
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    if (archive.length > maxEntries) {
      throw 'The zip has too many files (${archive.length})';
    }
    var total = 0;
    for (final f in archive) {
      total += f.size;
    }
    if (total > maxTotalBytes) {
      throw 'The zip is unreasonably large when unpacked';
    }

    Directory(destDir).createSync(recursive: true);
    final root = p.canonicalize(destDir);
    var written = 0;

    for (final f in archive) {
      if (f.isSymbolicLink) continue;
      final parts = _safeParts(f.name);
      if (parts == null) continue;
      final target = p.joinAll([root, ...parts]);
      if (!p.isWithin(root, target)) {
        throw 'The zip contains an unsafe path (${f.name})';
      }
      if (!f.isFile) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      Directory(p.dirname(target)).createSync(recursive: true);
      final out = OutputFileStream(target);
      try {
        f.writeContent(out);
      } finally {
        out.closeSync();
      }
      written++;
      if (Platform.isWindows &&
          _markedExts.contains(p.extension(target).toLowerCase())) {
        try {
          File('$target:Zone.Identifier')
              .writeAsStringSync('[ZoneTransfer]\r\nZoneId=3\r\n');
        } catch (_) {
          // Best effort: not every drive supports alternate data streams.
        }
      }
    }
    return written;
  } finally {
    input.closeSync();
  }
}
