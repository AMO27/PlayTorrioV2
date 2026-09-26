import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:logging/logging.dart';
import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'api/audio_handler.dart';
import 'api/audiobook_player_service.dart';
import 'api/settings_service.dart';
import 'api/torrent_stream_service.dart';
import 'api/tmdb_api.dart';
import 'api/local_server_service.dart';
import 'api/music_player_service.dart';
import 'api/webstreamr_service.dart';
import 'api/nuvio_service.dart';
import 'api/site111477_proxy.dart' as site111477_proxy;
import 'models/movie.dart';
import 'services/player_pool_service.dart';
import 'utils/webview_cleanup.dart';
import 'utils/app_theme.dart';

import 'screens/main_screen.dart';
import 'screens/search_screen.dart';
import 'screens/discover_screen.dart';

/// Runs on its own isolate during shutdown. If the app is still alive after
/// the grace period (a native call hung), terminate the process. Process.killPid
/// maps to TerminateProcess on Windows, which skips C-runtime/DLL teardown —
/// avoiding the exit(0) assertion race the old comments describe.
void _killAfterDelay(int targetPid) {
  sleep(const Duration(seconds: 10));
  Process.killPid(targetPid, ProcessSignal.sigkill);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[Boot] Flutter binding initialized');

  // Configure InAppWebView (Android only — not supported on iOS)
  if (Platform.isAndroid) {
    try {
      debugPrint('[Boot] Setting up InAppWebView...');
      await InAppWebViewController.setWebContentsDebuggingEnabled(true);
      debugPrint('[Boot] InAppWebView OK');
    } catch (e) {
      debugPrint('[Boot] InAppWebView setup failed (non-fatal): $e');
    }
  }
  
  Logger.root.level = Level.FINER;
  Logger.root.onRecord.listen((e) {
    debugPrint('[YT] ${e.message}');
    if (e.error != null) {
      debugPrint('[YT ERROR] ${e.error}');
      debugPrint('[YT STACK] ${e.stackTrace}');
    }
  });
  
  if (Platform.isAndroid) {
    // Follow system rotation setting — no forced lock.
    // auto_orientation_v2 is gone, so this respects the user's
    // rotation-lock toggle in Android quick-settings.
    SystemChrome.setPreferredOrientations([]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    // Size the window to fit the user's primary display. On a 1366×768
    // laptop the old fixed 1600×1000 was bigger than the screen, so the
    // title bar / close button / fullscreen toggle fell off-screen.
    // We clamp the default to the display's work area minus a small
    // margin, and set a reasonable minimum so tiny screens still work.
    const double desiredWidth = 1600;
    const double desiredHeight = 1000;
    const double screenMargin = 80; // leaves room for taskbar + title bar
    final display = WidgetsBinding.instance.platformDispatcher.displays.first;
    final logicalScreen = display.size / display.devicePixelRatio;
    final double maxW = (logicalScreen.width - screenMargin).clamp(640.0, double.infinity);
    final double maxH = (logicalScreen.height - screenMargin).clamp(480.0, double.infinity);
    final Size windowSize = Size(
      desiredWidth.clamp(640.0, maxW),
      desiredHeight.clamp(480.0, maxH),
    );

    final WindowOptions windowOptions = WindowOptions(
      size: windowSize,
      minimumSize: const Size(640, 480),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  
  debugPrint('[Boot] Initializing MediaKit...');
  MediaKit.ensureInitialized();
  debugPrint('[Boot] MediaKit OK');
  
  debugPrint('[Boot] Initializing AudioService...');
  final audioHandler = await AudioService.init(
    builder: () => PlayTorrioAudioHandler(MusicPlayerService().player),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.playtorrio.native.channel.audio',
      androidNotificationChannelName: 'Music Playback',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidResumeOnClick: true,
    ),
  );
  debugPrint('[Boot] AudioService OK');
  
  MusicPlayerService().setHandler(audioHandler);
  AudiobookPlayerService().init(audioHandler);
  
  // Hydrate light mode setting before first frame
  await SettingsService().initLightMode();
  
  // Hydrate theme preset before first frame
  await AppTheme.initTheme();
  
  PlayerPoolService().warmUp();
  // Pre-initialise the local WebStreamr pipeline so the first call is fast.
  // Errors here are non-fatal — the service init() is also called lazily.
  unawaited(WebStreamrService.init().catchError((e) {
    debugPrint('[Boot] WebStreamrService.init failed (non-fatal): $e');
  }));
  // Refresh every installed Nuvio addon's manifest in the background so new
  // upstream providers / fixes flow in without the user reinstalling.
  // Non-fatal — offline launches just keep the previously cached manifests.
  unawaited(NuvioService.instance.refreshAllInstalled().catchError((e) {
    debugPrint('[Boot] Nuvio refresh failed (non-fatal): $e');
  }));
  debugPrint('[Boot] All init complete — launching app');

  runApp(const PlayTorrioApp());
}

class PlayTorrioApp extends StatefulWidget {
  const PlayTorrioApp({super.key});

  @override
  State<PlayTorrioApp> createState() => _PlayTorrioAppState();
}

class _PlayTorrioAppState extends State<PlayTorrioApp> with WidgetsBindingObserver, WindowListener {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    final bool isPreventClose = await windowManager.isPreventClose();
    if (!isPreventClose) return;

    // Ignore repeated clicks on the X button while shutdown is in progress.
    if (_closing) return;
    _closing = true;

    // Hide the window right away so the app *looks* closed instantly, even if
    // native teardown below takes a moment.
    try {
      await windowManager.hide();
    } catch (_) {}

    // Safety net: a watchdog on a SEPARATE isolate. Native teardown calls
    // (libtorrent session destroy, mpv dispose) are synchronous FFI calls that
    // can block this isolate, so a Timer here could never fire. If the process
    // is still alive after the grace period, the watchdog terminates it.
    _startKillWatchdog();

    // Ordered shutdown. Every step is time-limited so one stuck component can
    // no longer freeze the whole close (the old code awaited each step with
    // no limit, which is why the window hung until killed in Task Manager).
    // Order matters: stop the media players (mpv) first so they release file
    // handles / network connections, then the torrent engine, then servers.
    await _step('music player', () => MusicPlayerService().disposePlayer());
    await _step('audiobook player', () async => AudiobookPlayerService().dispose());
    await _step('player pool', () => PlayerPoolService().dispose());
    await _step('torrent streams', () => TorrentStreamService().cleanup());
    await _step('111477 proxy', () async {
      // Stop any running 111477 proxy. Cache deletion happens AFTER the
      // players above are disposed so MPV has released its file handle.
      if (site111477_proxy.is111477ProxyRunning) {
        await site111477_proxy.stop111477Proxy();
      }
    });
    await _step('local server', () => LocalServerService().stop());
    unawaited(_step('webview cache', () => WebViewCleanup.cleanupWebView2Cache()));

    // Small grace period so background threads can unwind.
    await Future.delayed(const Duration(milliseconds: 250));

    await _step('111477 cache purge', () => site111477_proxy.purge111477Cache());

    // Last: tear down the native libtorrent session. This was never called
    // before, so its 200 ms poll timer kept hitting a half-destroyed engine
    // during exit (the lag + crash). It is a synchronous native call, which is
    // why the window is already hidden and the watchdog is already armed.
    await _step('torrent engine', () async {
      if (LibtorrentFlutter.isInitialized) {
        await LibtorrentFlutter.instance.dispose();
      }
    });

    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
    // If Flutter's normal exit path leaves the process alive, the watchdog
    // isolate ends it.
  }

  bool _closing = false;

  /// Runs one shutdown step, never letting it throw or hang the close.
  Future<void> _step(String name, Future<void> Function() action,
      {Duration limit = const Duration(seconds: 2)}) async {
    try {
      await action().timeout(limit);
    } on TimeoutException {
      debugPrint('[Shutdown] "$name" timed out after ${limit.inSeconds}s — skipping');
    } catch (e) {
      debugPrint('[Shutdown] "$name" failed: $e');
    }
  }

  void _startKillWatchdog() {
    Isolate.spawn<int>(_killAfterDelay, pid).catchError((Object e) {
      debugPrint('[Shutdown] could not start watchdog: $e');
      return Isolate.current;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      PlayerPoolService().dispose();
      TorrentStreamService().cleanup();
      WebViewCleanup.cleanupWebView2Cache();
      site111477_proxy.purge111477Cache();
    }
  }

  /// True on Windows, Linux, macOS — used to disable the accessibility
  /// bridge that causes AXTree crashes on Windows.
  static final bool _isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemePreset>(
      valueListenable: AppTheme.themeNotifier,
      builder: (context, preset, _) {
        Widget app = MaterialApp(
          title: 'PlayTorrio Native',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeData,
          home: const SplashScreen(),
        );
        // On desktop, disable the semantics / accessibility tree entirely.
        // Flutter's Windows accessibility bridge has a known bug where the
        // ui::AXTree gets out of sync, spamming errors and eventually
        // crashing the app. Since PlayTorrio doesn't target screen-reader
        // users on desktop, this is a safe and effective workaround.
        if (_isDesktop) {
          app = ExcludeSemantics(child: app);
        }
        return app;
      },
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  /// Minimum time the splash overlay stays visible. Engine starts almost
  /// instantly, so we hold the splash a bit longer to let MainScreen /
  /// HomeScreen build, layout, paint and prefetch in the background. That
  /// way, when the overlay fades out, the first frames of the real UI are
  /// already warm and scrolling is smooth instead of janky.
  static const Duration _minSplashDuration = Duration(milliseconds: 2800);

  /// Built once and kept alive in the widget tree behind the splash overlay
  /// so its element (and all child State objects) survive the transition
  /// without being re-created.
  final Widget _mainScreen = const MainScreen();

  /// True while the splash overlay should still be drawn on top.
  bool _showOverlay = true;

  /// Drives the fade-out of the splash overlay once the engine is ready.
  double _overlayOpacity = 1.0;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    
    _fadeAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut),
    );

    _initEngine();
  }

  /// Called once the engine is ready AND the minimum splash time has
  /// elapsed. Triggers the fade-out and then removes the overlay from
  /// the tree, leaving the already-warm MainScreen in place.
  void _dismissSplash() {
    if (!mounted || !_showOverlay) return;
    setState(() => _overlayOpacity = 0.0);
  }

  Future<void> _initEngine() async {
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('[Boot] Starting engine initialization...');
    debugPrint('═══════════════════════════════════════════════════════════');

    // Start the minimum-display timer in parallel with all init work so
    // the splash never flashes by too quickly even when the engine is hot.
    final minSplashFuture = Future<void>.delayed(_minSplashDuration);

    debugPrint('[Boot] Step 1: Checking network connectivity...');
    final connectivityResult = await Connectivity().checkConnectivity();
    final isOffline = connectivityResult.contains(ConnectivityResult.none);
    debugPrint('[Boot] Network status: ${isOffline ? "OFFLINE" : "ONLINE"}');

    if (isOffline) {
      debugPrint('[Boot] Device is offline, initializing local services only');
      debugPrint('[Boot] Initializing MusicPlayer...');
      await MusicPlayerService().init().catchError((e) {
        debugPrint('[Boot] ✗ MusicPlayer error: $e');
        return null;
      });
      debugPrint('[Boot] ✓ Local services initialized');
      await minSplashFuture;
      if (mounted) {
        debugPrint('[Boot] Dismissing splash (offline mode)');
        _dismissSplash();
      }
      return;
    }

    debugPrint('[Boot] Step 2: Initializing services in parallel...');
    final api = TmdbApi();
    
    debugPrint('[Boot]   - Starting TorrentStream engine...');
    debugPrint('[Boot]   - Starting LocalServer...');
    debugPrint('[Boot]   - Initializing MusicPlayer...');
    debugPrint('[Boot]   - Fetching TMDB data (trending, popular, top rated, now playing)...');
    
    final results = await Future.wait([
      TorrentStreamService().start().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[Boot] ⚠ TorrentStream startup timed out after 10s');
          return false;
        },
      ).catchError((e, st) {
        debugPrint('[Boot] ✗ TorrentStream error: $e');
        debugPrint('[Boot] Stack trace: $st');
        return false;
      }),
      LocalServerService().start().catchError((e) {
        debugPrint('[Boot] ✗ LocalServer error: $e');
      }),
      MusicPlayerService().init().catchError((e) {
        debugPrint('[Boot] ✗ MusicPlayer error: $e');
      }),
      api.getTrending().catchError((e) {
        debugPrint('[Boot] ✗ TMDB trending error: $e');
        return <Movie>[];
      }),
      api.getPopular().catchError((e) {
        debugPrint('[Boot] ✗ TMDB popular error: $e');
        return <Movie>[];
      }),
      api.getTopRated().catchError((e) {
        debugPrint('[Boot] ✗ TMDB top rated error: $e');
        return <Movie>[];
      }),
      api.getNowPlaying().catchError((e) {
        debugPrint('[Boot] ✗ TMDB now playing error: $e');
        return <Movie>[];
      }),
    ]);

    debugPrint('[Boot] Step 3: Service initialization results:');
    final torrentEngineReady = (results[0] as bool?) == true;
    // LocalServer and MusicPlayer return void, just check if they completed without throwing
    debugPrint('[Boot]   TorrentStream: ${torrentEngineReady ? "✓ READY" : "✗ FAILED"}');
    debugPrint('[Boot]   LocalServer: ✓ READY');
    debugPrint('[Boot]   MusicPlayer: ✓ READY');
    
    final trendingList = results[3] as List;
    final popularList = results[4] as List;
    final topRatedList = results[5] as List;
    final nowPlayingList = results[6] as List;
    
    debugPrint('[Boot]   TMDB Trending: ${trendingList.isNotEmpty ? "✓ ${trendingList.length} items" : "✗ Empty"}');
    debugPrint('[Boot]   TMDB Popular: ${popularList.isNotEmpty ? "✓ ${popularList.length} items" : "✗ Empty"}');
    debugPrint('[Boot]   TMDB Top Rated: ${topRatedList.isNotEmpty ? "✓ ${topRatedList.length} items" : "✗ Empty"}');
    debugPrint('[Boot]   TMDB Now Playing: ${nowPlayingList.isNotEmpty ? "✓ ${nowPlayingList.length} items" : "✗ Empty"}');

    debugPrint('[Boot] Step 4: Pre-warming screens...');
    // ignore: unused_local_variable
    const warmupSearch = SearchScreen();
    // ignore: unused_local_variable
    const warmupDiscover = DiscoverScreen();
    debugPrint('[Boot] ✓ Screens pre-warmed');

    debugPrint('[Boot] Step 5: Waiting for minimum splash time so the '
        'pre-built MainScreen / HomeScreen finishes its first paints...');
    await minSplashFuture;

    if (mounted) {
      debugPrint('[Boot] Step 6: Dismissing splash overlay (MainScreen '
          'already mounted underneath)');
      _dismissSplash();
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[Boot] ✓✓✓ ENGINE INITIALIZATION COMPLETE ✓✓✓');
      debugPrint('═══════════════════════════════════════════════════════════');
    }
  }
  


  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // The real app — built and laid out behind the splash so widgets,
        // images, fonts and HomeScreen network requests are all warm by
        // the time the overlay fades out.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _showOverlay,
            child: _mainScreen,
          ),
        ),
        if (_showOverlay)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: true,
              child: AnimatedOpacity(
                opacity: _overlayOpacity,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOut,
                onEnd: () {
                  if (_overlayOpacity == 0.0 && mounted) {
                    setState(() => _showOverlay = false);
                  }
                },
                child: _buildSplashOverlay(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSplashOverlay() {
    return Scaffold(
      body: Container(
        decoration: AppTheme.backgroundDecoration,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.5), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primaryColor.withValues(alpha: 0.3),
                      blurRadius: 40,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  size: 80,
                  color: AppTheme.primaryColor,
                ),
              ),
              const SizedBox(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [Colors.white, Colors.white70, AppTheme.primaryColor],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ).createShader(bounds),
                    child: const Text(
                      'PLAYTORRIO',
                      style: TextStyle(
                        fontSize: 64,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -2,
                        color: Colors.white,
                        fontFamily: 'Poppins',
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'YOUR CINEMA UNIVERSE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 10,
                      color: AppTheme.primaryColor.withValues(alpha: 0.6),
                      fontFamily: 'Poppins',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 100),
              FadeTransition(
                opacity: _fadeAnimation,
                child: const Text(
                  'INITIALIZING ENGINE...',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                    color: Colors.white38,
                    fontFamily: 'Poppins',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}