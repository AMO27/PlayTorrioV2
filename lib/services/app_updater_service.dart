import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdaterService {
  // Point at this fork's own releases. Pointing at the upstream repo would
  // offer upstream builds as "updates" and silently replace this fork's
  // fixes. If this fork has no GitHub Releases, the check simply finds no
  // update.
  static const String githubRepo = 'AMO27/PlayTorrioV2';
  static const String githubApiUrl = 'https://api.github.com/repos/$githubRepo/releases/latest';
  
  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      
      final response = await http.get(Uri.parse(githubApiUrl));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final latestVersion = (data['tag_name'] as String).replaceFirst('v', '');
        final releaseNotes = data['body'] as String? ?? 'No release notes available';
        final publishedAt = DateTime.parse(data['published_at']);
        
        if (_isNewerVersion(currentVersion, latestVersion)) {
          // Find the appropriate download URL based on platform
          String? downloadUrl;
          String? sha256;
          // GitHub publishes a "sha256:<hex>" digest for each release asset;
          // the downloader checks the file against it.
          String? digestOf(dynamic asset) {
            final d = asset is Map ? asset['digest'] : null;
            if (d is String && d.toLowerCase().startsWith('sha256:')) {
              return d.substring(7).toLowerCase();
            }
            return null;
          }
          final assets = data['assets'] as List;
          
          if (Platform.isWindows) {
            final asset = assets.firstWhere(
              (a) => (a['name'] as String).toLowerCase().contains('windows') && 
                     (a['name'] as String).endsWith('.exe'),
              orElse: () => null,
            );
            downloadUrl = asset?['browser_download_url'];
            sha256 = digestOf(asset);
          } else if (Platform.isLinux) {
            final asset = assets.firstWhere(
              (a) => (a['name'] as String).toLowerCase().contains('linux') && 
                     ((a['name'] as String).endsWith('.AppImage') || 
                      (a['name'] as String).endsWith('.deb')),
              orElse: () => null,
            );
            downloadUrl = asset?['browser_download_url'];
            sha256 = digestOf(asset);
          } else if (Platform.isMacOS) {
            // For macOS, we'll just link to the releases page
            downloadUrl = data['html_url'];
          } else if (Platform.isAndroid) {
            final asset = assets.firstWhere(
              (a) => (a['name'] as String).toLowerCase().endsWith('.apk'),
              orElse: () => null,
            );
            downloadUrl = asset?['browser_download_url'];
            sha256 = digestOf(asset);
          } else if (Platform.isIOS) {
            // iOS can't auto-install — link to releases page
            downloadUrl = data['html_url'];
          }
          
          return UpdateInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            downloadUrl: downloadUrl ?? data['html_url'],
            releaseNotes: releaseNotes,
            publishedAt: publishedAt,
            isMacOS: Platform.isMacOS,
            isIOS: Platform.isIOS,
            sha256: sha256,
          );
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error checking for updates: $e');
      return null;
    }
  }
  
  bool _isNewerVersion(String current, String latest) {
    final currentParts = current.split('.').map(int.parse).toList();
    final latestParts = latest.split('.').map(int.parse).toList();
    
    for (int i = 0; i < 3; i++) {
      final currentPart = i < currentParts.length ? currentParts[i] : 0;
      final latestPart = i < latestParts.length ? latestParts[i] : 0;
      
      if (latestPart > currentPart) return true;
      if (latestPart < currentPart) return false;
    }
    return false;
  }
  
  Future<void> openDownloadPage(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;
  final String releaseNotes;
  final DateTime publishedAt;
  final bool isMacOS;
  final bool isIOS;
  /// Expected SHA-256 (lowercase hex) of the download, when GitHub provides it.
  final String? sha256;
  
  UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.publishedAt,
    required this.isMacOS,
    this.isIOS = false,
    this.sha256,
  });
}
