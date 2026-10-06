import 'package:flutter/material.dart';
import 'games_sites_tab.dart';
import 'saved_sites_store.dart';

/// Play tab: sites where games run in the browser. This list is separate
/// from the Download tab's list.
class GamesPlayTab extends StatelessWidget {
  const GamesPlayTab({super.key});

  static final SavedSitesStore store = SavedSitesStore('games_play_sites', () => [
        SavedSite('RetroGames', 'https://www.retrogames.cc/'),
        SavedSite('Poki', 'https://poki.com/'),
        SavedSite('now.gg', 'https://now.gg/'),
      ]);

  @override
  Widget build(BuildContext context) {
    return GamesSitesTab(
      store: store,
      intro:
          'Pick a site to play in the app. Tap the star inside a site to save the page you are on.',
    );
  }
}
