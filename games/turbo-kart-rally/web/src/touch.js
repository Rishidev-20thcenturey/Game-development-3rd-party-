// Touch controls + Android app glue for the mobile build of Turbo Kart Rally.
//
// The original game reads the keyboard (and gamepads) through InputController. Rather than
// changing the driving code, this module turns on-screen touch buttons into the same
// KeyboardEvents (by `event.code`) the game already understands, so desktop behaviour is untouched.
//
// Layout (landscape):  left thumb  -> steering pad (slide between ◀ and ▶)
//                      right thumb -> DRIFT (hold), ITEM, BRAKE, GAS
//                      top-right   -> pause; auto-gas toggle; sound toggle on menus
// Auto-gas (default on) holds the throttle for you once the race is running, which is how most
// mobile kart racers play. Holding GAS during the countdown still gives the rocket start.

const SND_ON = '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M16 8.5a5 5 0 0 1 0 7" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round"/><path d="M18.5 6a8.5 8.5 0 0 1 0 12" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round"/></svg>';
const SND_OFF = '<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M16 9l5 6M21 9l-5 6" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
const PLATFORM = window.TKR_PLATFORM || { touch: false, androidApp: false };

const KEY = {
  accelerate: { code: 'ArrowUp', key: 'ArrowUp' },
  brake: { code: 'ArrowDown', key: 'ArrowDown' },
  left: { code: 'ArrowLeft', key: 'ArrowLeft' },
  right: { code: 'ArrowRight', key: 'ArrowRight' },
  drift: { code: 'Space', key: ' ' },
  item: { code: 'KeyE', key: 'e' },
  lookBack: { code: 'KeyC', key: 'c' },
  pause: { code: 'Escape', key: 'Escape' },
  mute: { code: 'KeyM', key: 'm' },
};

const held = new Set(); // action names currently pressed by touch
function press(action) {
  if (held.has(action)) return;
  held.add(action);
  const k = KEY[action];
  window.dispatchEvent(new KeyboardEvent('keydown', { code: k.code, key: k.key, bubbles: true, cancelable: true }));
}
function release(action) {
  if (!held.has(action)) return;
  held.delete(action);
  const k = KEY[action];
  window.dispatchEvent(new KeyboardEvent('keyup', { code: k.code, key: k.key, bubbles: true, cancelable: true }));
}
function tap(action) { press(action); setTimeout(() => release(action), 60); }
function releaseAll() { for (const a of [...held]) release(a); }
function buzz(ms = 12) { try { if (navigator.vibrate) navigator.vibrate(ms); } catch { /* ignore */ } }

function game() { return window.__game || null; }
function gameState() { const g = game(); return g ? g.state : 'boot'; }
function resultsVisible() { return !!document.querySelector('.results.show'); }

// ----------------------------------------------------------------------------------------------
// Android hardware/gesture back button (called from MainActivity). Returns 'exit' at the title.
// ----------------------------------------------------------------------------------------------
window.__tkrBack = function () {
  const g = game();
  const st = gameState();
  if (!g) return 'exit';
  if (resultsVisible()) {
    const menuBtn = document.querySelector('.results .btn[data-act="menu"]');
    if (menuBtn) { menuBtn.click(); return 'handled'; }
  }
  if (st === 'select') { if (g.menu && g.menu._toTitle) g.menu._toTitle(); return 'handled'; }
  if (st === 'paused' || st === 'intro' || st === 'countdown' || st === 'racing') { releaseAll(); tap('pause'); return 'handled'; }
  if (st === 'finished') { if (g.goToTitle) g.goToTitle(); return 'handled'; }
  return 'exit';
};

// Pause + silence the game when the app goes to the background (called from MainActivity too).
function suspendAudio() { try { const ctx = game()?.audio?.ctx; if (ctx && ctx.state === 'running') ctx.suspend(); } catch { /* ignore */ } }
function resumeAudio() { try { const ctx = game()?.audio?.ctx; if (ctx && ctx.state === 'suspended') ctx.resume(); } catch { /* ignore */ } }
window.__tkrAppPause = function () { releaseAll(); suspendAudio(); };
window.__tkrAppResume = function () { resumeAudio(); };
document.addEventListener('visibilitychange', () => { if (document.hidden) window.__tkrAppPause(); else window.__tkrAppResume(); });

if (PLATFORM.touch) initTouch();

function initTouch() {
  document.addEventListener('contextmenu', (e) => e.preventDefault());
  // Stop double-tap zoom / pull-to-refresh / scroll bounce while playing.
  document.addEventListener('touchmove', (e) => { if (!e.target.closest('.select-screen, .res-table')) e.preventDefault(); }, { passive: false });
  document.addEventListener('dblclick', (e) => e.preventDefault());

  const root = document.getElementById('game-root') || document.body;
  const ui = document.createElement('div');
  ui.id = 'touch-ui';
  ui.innerHTML = `
    <div class="tc-steer" aria-label="Steer">
      <div class="tc-steer-btn l"><span>◀</span></div>
      <div class="tc-steer-btn r"><span>▶</span></div>
    </div>
    <div class="tc-cluster">
      <button class="tc-btn tc-item" data-a="item" aria-label="Use item"><span>ITEM</span></button>
      <button class="tc-btn tc-brake" data-a="brake" aria-label="Brake"><span>BRAKE</span></button>
      <button class="tc-btn tc-drift" data-a="drift" aria-label="Hop and drift"><span>DRIFT</span></button>
      <button class="tc-btn tc-gas" data-a="accelerate" aria-label="Accelerate"><span>GAS</span></button>
    </div>
    <div class="tc-top">
      <button class="tc-pill tc-auto" aria-label="Toggle auto accelerate"></button>
      <button class="tc-round tc-look" data-a="lookBack" aria-label="Look back"><svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2"><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3" fill="currentColor"/></svg></button>
      <button class="tc-round tc-pause" aria-label="Pause">❚❚</button>
    </div>
    <button class="tc-round tc-sound" aria-label="Toggle sound"></button>
    <div class="tc-hint">TAP TO SKIP</div>`;
  root.appendChild(ui);

  // ---- auto-gas setting -------------------------------------------------------------------
  let autoGas = true;
  try { const v = localStorage.getItem('tkr-autogas'); if (v !== null) autoGas = v === '1'; } catch { /* ignore */ }
  const autoBtn = ui.querySelector('.tc-auto');
  const renderAuto = () => { autoBtn.textContent = autoGas ? 'AUTO-GAS ON' : 'AUTO-GAS OFF'; autoBtn.classList.toggle('on', autoGas); ui.classList.toggle('autogas', autoGas); };
  renderAuto();
  autoBtn.addEventListener('pointerdown', (e) => {
    e.preventDefault(); e.stopPropagation();
    autoGas = !autoGas; buzz();
    try { localStorage.setItem('tkr-autogas', autoGas ? '1' : '0'); } catch { /* ignore */ }
    renderAuto();
  });

  // ---- hold buttons (multi-touch, each pointer owns one button) -----------------------------
  const btnHeld = new Set();
  for (const b of ui.querySelectorAll('.tc-btn, .tc-look')) {
    const action = b.dataset.a;
    const down = (e) => {
      e.preventDefault(); e.stopPropagation();
      try { b.setPointerCapture(e.pointerId); } catch { /* ignore */ }
      b.classList.add('down'); btnHeld.add(action); buzz(action === 'item' ? 20 : 10);
      syncThrottle();
      if (action !== 'accelerate' && action !== 'brake') press(action);
    };
    const up = (e) => {
      e.preventDefault();
      b.classList.remove('down'); btnHeld.delete(action);
      if (action !== 'accelerate' && action !== 'brake') release(action);
      syncThrottle();
    };
    b.addEventListener('pointerdown', down);
    b.addEventListener('pointerup', up);
    b.addEventListener('pointercancel', up);
    b.addEventListener('lostpointercapture', up);
  }

  // Throttle/brake are combined: brake overrides gas; auto-gas holds gas while racing.
  function syncThrottle() {
    const st = gameState();
    const racing = st === 'racing' && !resultsVisible();
    const wantBrake = btnHeld.has('brake');
    const wantGas = !wantBrake && (btnHeld.has('accelerate') || (autoGas && racing));
    if (wantBrake) press('brake'); else release('brake');
    if (wantGas) press('accelerate'); else release('accelerate');
  }

  // ---- steering pad: finger x relative to the pad centre picks left / right; slide to switch --
  const pad = ui.querySelector('.tc-steer');
  const padL = pad.querySelector('.l'), padR = pad.querySelector('.r');
  const steerPointers = new Map(); // pointerId -> -1 | 0 | 1
  function applySteer() {
    let dir = 0;
    for (const d of steerPointers.values()) if (d !== 0) dir = d; // last finger wins
    if (dir < 0) { press('left'); release('right'); } else if (dir > 0) { press('right'); release('left'); } else { release('left'); release('right'); }
    padL.classList.toggle('down', dir < 0); padR.classList.toggle('down', dir > 0);
  }
  function steerFromEvent(e) {
    const r = pad.getBoundingClientRect();
    const x = (e.clientX - r.left) / Math.max(1, r.width);
    return x < 0.44 ? -1 : x > 0.56 ? 1 : 0;
  }
  pad.addEventListener('pointerdown', (e) => {
    e.preventDefault(); e.stopPropagation();
    try { pad.setPointerCapture(e.pointerId); } catch { /* ignore */ }
    const d = steerFromEvent(e);
    if (d !== steerPointers.get(e.pointerId)) buzz(8);
    steerPointers.set(e.pointerId, d); applySteer();
  });
  pad.addEventListener('pointermove', (e) => {
    if (!steerPointers.has(e.pointerId)) return;
    const d = steerFromEvent(e);
    if (d !== steerPointers.get(e.pointerId)) { if (d !== 0) buzz(6); steerPointers.set(e.pointerId, d); applySteer(); }
  });
  const steerEnd = (e) => { if (steerPointers.delete(e.pointerId)) applySteer(); };
  pad.addEventListener('pointerup', steerEnd);
  pad.addEventListener('pointercancel', steerEnd);
  pad.addEventListener('lostpointercapture', steerEnd);

  // ---- pause / sound -----------------------------------------------------------------------
  ui.querySelector('.tc-pause').addEventListener('pointerdown', (e) => {
    e.preventDefault(); e.stopPropagation(); buzz();
    resetControls(); tap('pause');
  });
  const soundBtn = ui.querySelector('.tc-sound');
  renderSoundLater();
  function renderSoundLater() { setTimeout(() => renderSound(), 0); }
  const renderSound = () => { const m = !!game()?.audio?.muted; soundBtn.innerHTML = m ? SND_OFF : SND_ON; };
  soundBtn.addEventListener('pointerdown', (e) => {
    e.preventDefault(); e.stopPropagation(); buzz();
    tap('mute'); setTimeout(renderSound, 30);
  });

  function resetControls() {
    btnHeld.clear(); steerPointers.clear();
    for (const b of ui.querySelectorAll('.down')) b.classList.remove('down');
    releaseAll();
  }

  // ---- visibility per game state -----------------------------------------------------------
  let lastState = '';
  let lastResults = false;
  function tick() {
    const st = gameState();
    const res = resultsVisible();
    if (st !== lastState || res !== lastResults) {
      const prev = lastState;
      lastState = st; lastResults = res;
      ui.dataset.state = res ? 'results' : st;
      const driving = (st === 'countdown' || st === 'racing') && !res;
      if (!driving || prev === 'paused') resetControls();
      renderSound();
    }
    if (st === 'racing' || st === 'countdown') syncThrottle();
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
  window.addEventListener('blur', resetControls);
}
