import 'package:flutter/material.dart';
import '../../api/games_service.dart';
import '../../utils/app_theme.dart';

/// Settings block for the Games section: the free Twitch / IGDB keys that
/// unlock console games in Upcoming and in the Library search. The keys are
/// kept only on this device.
class GamesIgdbSettings extends StatefulWidget {
  const GamesIgdbSettings({super.key});

  @override
  State<GamesIgdbSettings> createState() => _GamesIgdbSettingsState();
}

class _GamesIgdbSettingsState extends State<GamesIgdbSettings> {
  final _id = TextEditingController();
  final _secret = TextEditingController();
  bool _busy = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    IgdbGames.credentials().then((c) {
      if (c != null && mounted) {
        _id.text = c.$1;
        _secret.text = c.$2;
      }
    });
  }

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save({bool test = false}) async {
    await IgdbGames.saveCredentials(_id.text, _secret.text);
    if (!test) {
      setState(() => _result = _id.text.trim().isEmpty && _secret.text.trim().isEmpty
          ? 'Keys removed.'
          : 'Saved on this device. Pull down in Games > Upcoming to reload.');
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final r = await IgdbGames.search('zelda');
      _result = r.isEmpty
          ? 'Connected, but the search returned nothing.'
          : '✅ Works. Console games are enabled.';
    } catch (e) {
      _result = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      );

  @override
  Widget build(BuildContext context) {
    final ok = _result != null && _result!.startsWith('✅');
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Console games (PS5, Xbox, Switch) in Games > Upcoming come from IGDB. '
            'Create a free app at dev.twitch.tv/console and paste its Client ID and Client Secret here. '
            'They stay on this device only. Without them, Upcoming shows PC games from Steam.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 14),
          const Text('Twitch Client ID',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          TextField(
              controller: _id,
              autocorrect: false,
              decoration: _dec('Client ID')),
          const SizedBox(height: 12),
          const Text('Twitch Client Secret',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          TextField(
              controller: _secret,
              obscureText: true,
              autocorrect: false,
              decoration: _dec('Client Secret')),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : () => _save(test: true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save & test'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : () => _save(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
          if (_result != null) ...[
            const SizedBox(height: 12),
            Text(_result!,
                style: TextStyle(
                    color: ok ? Colors.green : Colors.orangeAccent,
                    fontSize: 13)),
          ],
        ],
      ),
    );
  }
}
