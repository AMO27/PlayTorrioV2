import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:youtube_explode_dart/js_challenge.dart';

/// Solves YouTube's JavaScript "challenges" (signature + n-parameter) using
/// the device's own JavaScript engine, via a hidden WebView.
///
/// youtube_explode_dart ships yt-dlp's EJS challenge solver but only runs it
/// through Deno, which doesn't exist on iOS/Android. This runs the exact same
/// solver scripts in a headless WebView instead (WKWebView on iOS), which
/// unlocks the YouTube clients that need challenges solved (Safari, TV) — the
/// same trick yt-dlp itself relies on.
class WebViewEJSSolver extends BaseEJSSolver {
  final HeadlessInAppWebView _view;
  final InAppWebViewController _controller;

  WebViewEJSSolver._(this._view, this._controller);

  static Future<WebViewEJSSolver> init() async {
    // Downloads yt-dlp's solver scripts (hash-verified by the library).
    final modules = await EJSBuilder.getJSModules()
        .timeout(const Duration(seconds: 15));

    final ready = Completer<InAppWebViewController>();
    final view = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: '<!DOCTYPE html><html><head></head><body></body></html>',
      ),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
      onLoadStop: (controller, _) {
        if (!ready.isCompleted) ready.complete(controller);
      },
    );
    await view.run();
    try {
      final controller =
          await ready.future.timeout(const Duration(seconds: 15));
      // Load the solver into the page's global scope. Wrap in a function
      // call that returns a plain value so evaluateJavascript doesn't try to
      // serialise whatever the last statement evaluates to.
      await controller.evaluateJavascript(source: '$modules\n;true;');
      final ok = await controller.evaluateJavascript(
          source: 'typeof jsc === "function"');
      if (ok != true) {
        throw Exception('EJS solver did not load in WebView');
      }
      return WebViewEJSSolver._(view, controller);
    } catch (e) {
      try {
        await view.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<String> executeJavaScript(String jsCode) async {
    final result = await _controller
        .evaluateJavascript(source: jsCode)
        .timeout(const Duration(seconds: 30));
    if (result is String) return result;
    throw Exception('JS solver returned ${result.runtimeType}');
  }

  @override
  void dispose() {
    unawaited(_view.dispose().catchError((Object e) {
      debugPrint('WebViewEJSSolver: dispose failed: $e');
    }));
  }
}
