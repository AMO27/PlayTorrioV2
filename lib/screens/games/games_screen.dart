import 'dart:io';
import 'package:flutter/material.dart';
import '../../utils/app_theme.dart';
import 'games_download_tab.dart';
import 'games_library_tab.dart';
import 'games_play_tab.dart';
import 'games_upcoming_tab.dart';

/// Games section: Play, Upcoming, Library and (Windows only) Download.
class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key});

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final List<_GameTab> _items;

  @override
  void initState() {
    super.initState();
    _items = [
      _GameTab('Play', Icons.play_circle_outline, const GamesPlayTab()),
      _GameTab('Upcoming', Icons.upcoming_outlined,
          const GamesUpcomingTab()),
      _GameTab('Library', Icons.collections_bookmark_outlined,
          const GamesLibraryTab()),
      if (Platform.isWindows)
        _GameTab('Download', Icons.download_outlined,
            const GamesDownloadTab()),
    ];
    _tabs = TabController(length: _items.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            TabBar(
              controller: _tabs,
              indicatorColor: AppTheme.current.primaryColor,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              dividerColor: Colors.white10,
              tabs: _items
                  .map((t) => Tab(icon: Icon(t.icon, size: 20), text: t.label))
                  .toList(),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                // Swiping would fight with the web pages inside the tabs.
                physics: const NeverScrollableScrollPhysics(),
                children: _items.map((t) => t.body).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameTab {
  final String label;
  final IconData icon;
  final Widget body;
  _GameTab(this.label, this.icon, this.body);
}
