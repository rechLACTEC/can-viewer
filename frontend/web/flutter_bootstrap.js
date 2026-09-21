{{flutter_js}}
{{flutter_build_config}}

// All engine resources stay on the application server, including any fallback
// font lookup. Bundled fonts cover the application's Portuguese text/symbols.
// No service worker or previously populated browser cache is required.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: new URL("canvaskit/", document.baseURI).href,
    fontFallbackBaseUrl: new URL("assets/assets/fonts/", document.baseURI).href,
  },
});
