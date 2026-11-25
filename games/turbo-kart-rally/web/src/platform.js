// Platform detection for the mobile / Android build. Runs before the game modules load.
// Sets `html.touch` when the device has a coarse pointer (phones, tablets) or when the page is
// opened with ?touch=1, and `html.android-app` inside the packaged Android WebView.
(function () {
  var q = location.search || '';
  var forced = /[?&]touch=1\b/.test(q);
  var disabled = /[?&]touch=0\b/.test(q);
  var coarse = false;
  try { coarse = window.matchMedia && window.matchMedia('(pointer: coarse)').matches; } catch (e) { /* ignore */ }
  var touch = !disabled && (forced || coarse || (navigator.maxTouchPoints || 0) > 0 && !window.matchMedia('(pointer: fine)').matches);
  var app = /TurboKartRallyApp\//.test(navigator.userAgent);
  window.TKR_PLATFORM = { touch: touch, androidApp: app };
  var cl = document.documentElement.classList;
  if (touch) cl.add('touch');
  if (app) cl.add('android-app');
})();
