// An interactive macOS desktop for the Still landing page: a scaled 1280x800 "screen" with a
// real menu bar, Control Center, four draggable app windows that make real sound, a Dock, and
// physical devices sitting on the table beside the laptop. Everything reacts to StillState and
// AudioEngine (see state.js / audio.js) so the visitor can actually use Still to tame the noise.
import { APPS } from './state.js';

const REDUCE_MOTION = matchMedia('(prefers-reduced-motion: reduce)').matches;
const TRACK_LEN = 222; // seconds, "Late Night Drive — Demo Tape"

const APP_ICON = { music: 'app-music', browser: 'app-browser', calls: 'app-calls', pings: 'app-pings' };
const APP_COLOR = { music: 'var(--ember)', browser: 'var(--blue)', calls: 'var(--mint)', pings: 'var(--violet)' };

// Initial window geometry — overlapping, like a busy real desktop. Later windows in this list
// sit on top of earlier ones at mount time.
const LAYOUT = [
  { id: 'calls', title: 'Calls', x: 92, y: 366, w: 452, h: 292 },
  { id: 'pings', title: 'Pings', x: 733, y: 380, w: 352, h: 316 },
  { id: 'music', title: 'Music', x: 64, y: 72, w: 416, h: 296 },
  { id: 'browser', title: 'Browser', x: 486, y: 54, w: 548, h: 372 },
];

const MENUS = {
  File: ['New Window ⌘N', 'New Tab ⌘T', '—', 'Open Recent', '—', 'Close Window ⌘W', 'Save ⌘S', 'Export…'],
  Edit: ['Undo ⌘Z', 'Redo ⇧⌘Z', '—', 'Cut ⌘X', 'Copy ⌘C', 'Paste ⌘V', '—', 'Select All ⌘A'],
  View: ['Show Toolbar', 'Show Sidebar ⌥⌘S', '—', 'Actual Size ⌘0', 'Zoom In ⌘+', 'Zoom Out ⌘-'],
  Window: ['Minimize ⌘M', 'Zoom', '—', 'Bring All to Front'],
  Help: ['Still Demo Help', '—', 'Report a Problem…'],
};

const CHAT_SEED = [
  { from: 'Priya', text: 'morning! standup in 10' },
  { from: 'Marcus', text: 'lgtm 🚀' },
];

const CALLERS = [
  { initials: 'JD', color: 'var(--blue)', name: 'Jae' },
  { initials: 'KP', color: 'var(--mint)', name: 'Kavi' },
  { initials: 'RS', color: 'var(--lavender)', name: 'Robin' },
];

let INSTANCE = 0;

export function mountDesktop(root, { state, engine }) {
  const uid = `md${++INSTANCE}`;
  root.classList.add('mac-demo-root');
  root.innerHTML = markup(uid);

  const $ = sel => root.querySelector(sel);
  const $$ = sel => Array.from(root.querySelectorAll(sel));

  const stage = $('.mac-stage');
  const scaleWrap = $('.mac-scale-wrap');
  const mac = $('.mac');
  const appNameEl = $('.mac-menubar-appname');
  const clockEl = $('.mac-clock');
  const statusStill = $('.mac-status-still');
  const statusCC = $('.mac-status-cc');
  const ccPanel = $('.mac-controlcenter');
  const panelHost = $('.mac-panel-host');
  const gate = $('.mac-gate');
  const gateButton = $('.mac-gate-button');
  const dock = $('.mac-dock');
  const notifications = $('.mac-notifications');
  const wallpaperWave = $('.mac-wave-main');

  // ---------------------------------------------------------------- scale + compact switching
  let compact = false;
  const ro = new ResizeObserver(entries => {
    const width = entries[0].contentRect.width;
    compact = width < 760;
    stage.classList.toggle('is-compact', compact);
    if (!compact) {
      // The bezel is the 1280px screen plus a 16px border on each side.
      const scale = Math.min(1, Math.max(0.32, width / 1312));
      scaleWrap.style.transform = `scale(${scale})`;
      scaleWrap.style.width = '1280px';
      scaleWrap.style.height = '800px';
      const laptop = $('.mac-laptop');
      laptop.style.setProperty('--scale', scale);
    }
    if (compact && panel && !panel.isOpen()) openPanel();
  });
  ro.observe(stage);

  // -------------------------------------------------------------------------------- still panel
  let panel = null;
  import('./panel.js').then(mod => {
    panel = mod.createPanel({
      state, engine,
      // panel.js calls this after it has already closed itself (Escape, "Quit Still"…),
      // so just resync our chrome — and in compact mode, snap it back open.
      onClose: () => { syncStatusStill(); if (compact) openPanel(); },
    });
    panel.element.hidden = true; // panel.css never hides .still-panel itself — that's on us
    panelHost.appendChild(panel.element);
    if (compact) openPanel();
    syncStatusStill();
  }).catch(err => console.error('Still demo: could not load panel.js', err));

  function openPanel() { if (!panel) return; panel.open(); syncStatusStill(); }
  function closePanelUI() { if (!panel) return; panel.close(); syncStatusStill(); }
  function togglePanel() {
    if (!panel) return;
    if (panel.isOpen()) closePanelUI(); else openPanel();
  }
  statusStill.addEventListener('click', e => { e.stopPropagation(); togglePanel(); });
  document.addEventListener('click', e => {
    if (compact || !panel || !panel.isOpen()) return;
    if (panel.element.contains(e.target) || statusStill.contains(e.target)) return;
    closePanelUI();
  });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && !compact) closePanelUI();
  });
  function syncStatusStill() {
    const open = !!(panel && panel.isOpen());
    statusStill.classList.toggle('is-open', open);
    statusStill.classList.toggle('is-dim', !state.enabled);
    if (panel) panel.element.hidden = !open;
  }

  // --------------------------------------------------------------------------------- menu bar
  $$('.mac-menu-item').forEach(btn => {
    const name = btn.dataset.menu;
    const dropdown = btn.nextElementSibling;
    btn.addEventListener('click', e => {
      e.stopPropagation();
      const open = dropdown.classList.contains('is-open');
      closeAllMenus();
      if (!open) { dropdown.classList.add('is-open'); btn.setAttribute('aria-expanded', 'true'); }
    });
  });
  function closeAllMenus() {
    $$('.mac-menu-dropdown').forEach(d => d.classList.remove('is-open'));
    $$('.mac-menu-item').forEach(b => b.setAttribute('aria-expanded', 'false'));
  }
  document.addEventListener('click', closeAllMenus);
  document.addEventListener('keydown', e => { if (e.key === 'Escape') closeAllMenus(); });

  // ---------------------------------------------------------------------------- control center
  statusCC.addEventListener('click', e => {
    e.stopPropagation();
    const open = ccPanel.classList.toggle('is-open');
    statusCC.setAttribute('aria-expanded', String(open));
    if (open) refreshControlCenter();
  });
  document.addEventListener('click', e => {
    if (!ccPanel.classList.contains('is-open')) return;
    if (ccPanel.contains(e.target) || statusCC.contains(e.target)) return;
    ccPanel.classList.remove('is-open');
    statusCC.setAttribute('aria-expanded', 'false');
  });
  const soundSlider = $('.mac-cc-sound input');
  soundSlider.addEventListener('input', e => engine.setSystemVolume(Number(e.target.value) / 100));
  function refreshControlCenter() { soundSlider.value = String(Math.round(engine.systemVolume * 100)); renderOutputs(); }
  const outputList = $('.mac-cc-outputs');
  function renderOutputs() {
    outputList.innerHTML = state.availableDevices().map(d => `
      <button type="button" class="mac-cc-output${d.id === state.defaultDevice ? ' is-active' : ''}" data-device="${d.id}">
        <span class="mac-cc-output-check" aria-hidden="true">${d.id === state.defaultDevice ? '<svg><use href="assets/stickers.svg#check"/></svg>' : ''}</span>
        <span>${d.name}</span>
      </button>`).join('');
    $$('.mac-cc-output', outputList).forEach(b => b.addEventListener('click', () => { state.setDefaultDevice(b.dataset.device); refreshControlCenter(); }));
  }
  const appearanceTile = $('.mac-cc-appearance');
  appearanceTile.addEventListener('click', () => {
    const next = mac.dataset.appearance === 'dark' ? 'light' : 'dark';
    mac.dataset.appearance = next;
    appearanceTile.classList.toggle('is-active', next === 'dark');
    appearanceTile.setAttribute('aria-pressed', String(next === 'dark'));
  });
  $$('.mac-cc-tile[data-decorative]').forEach(tile => {
    tile.addEventListener('click', () => {
      const active = tile.classList.toggle('is-active');
      tile.setAttribute('aria-pressed', String(active));
    });
  });

  // --------------------------------------------------------------------------------- windows
  const wins = new Map();
  LAYOUT.forEach((spec, i) => {
    const el = $(`.mac-window[data-window="${spec.id}"]`);
    el.style.left = spec.x + 'px';
    el.style.top = spec.y + 'px';
    el.style.width = spec.w + 'px';
    el.style.height = spec.h + 'px';
    wins.set(spec.id, { el, spec, z: i + 1, mode: 'open' });
  });
  let zTop = LAYOUT.length;
  let frontApp = LAYOUT[LAYOUT.length - 1].id;

  function focusWindow(id) {
    const w = wins.get(id);
    if (!w || w.mode !== 'open') return;
    zTop += 1; w.z = zTop; w.el.style.zIndex = String(zTop);
    frontApp = id;
    appNameEl.textContent = APPS.find(a => a.id === id).name;
  }
  wins.forEach((w, id) => { w.el.style.zIndex = String(w.z); w.el.addEventListener('mousedown', () => focusWindow(id)); });
  appNameEl.textContent = APPS.find(a => a.id === frontApp).name;

  function dockIconRect(id) {
    const icon = dock.querySelector(`.mac-dock-icon[data-app="${id}"]`);
    return icon ? icon.getBoundingClientRect() : mac.getBoundingClientRect();
  }
  function macRect() { return mac.getBoundingClientRect(); }
  function macScale() { const r = macRect(); return r.width / 1280 || 1; }

  function closeWindow(id) {
    const w = wins.get(id);
    w.mode = 'closed';
    w.el.classList.remove('is-genie');
    w.el.classList.add('is-hidden');
    engine.setPlaying(id, false);
    render();
  }
  function minimizeWindow(id) {
    const w = wins.get(id);
    if (w.mode !== 'open') return;
    const from = w.el.getBoundingClientRect();
    const to = dockIconRect(id);
    const s = macScale();
    const dx = (to.left + to.width / 2 - (from.left + from.width / 2)) / s;
    const dy = (to.top - (from.top + from.height / 2)) / s;
    w.mode = 'minimized';
    if (REDUCE_MOTION) { w.el.classList.add('is-hidden'); render(); return; }
    w.el.style.setProperty('--gx', dx + 'px');
    w.el.style.setProperty('--gy', dy + 'px');
    w.el.classList.add('is-genie');
    w.el.addEventListener('animationend', function done() {
      w.el.removeEventListener('animationend', done);
      w.el.classList.remove('is-genie');
      w.el.classList.add('is-hidden');
      render();
    }, { once: true });
  }
  function restoreWindow(id) {
    const w = wins.get(id);
    const wasClosed = w.mode === 'closed';
    w.mode = 'open';
    w.el.classList.remove('is-hidden');
    focusWindow(id);
    if (wasClosed) engine.setPlaying(id, true);
    if (!REDUCE_MOTION) {
      w.el.classList.add('is-bounce-in');
      w.el.addEventListener('animationend', function done() { w.el.removeEventListener('animationend', done); w.el.classList.remove('is-bounce-in'); }, { once: true });
    }
    render();
  }
  function wiggle(id) {
    const w = wins.get(id);
    if (REDUCE_MOTION) return;
    w.el.classList.remove('is-wiggle'); void w.el.offsetWidth;
    w.el.classList.add('is-wiggle');
  }

  wins.forEach((w, id) => {
    w.el.querySelector('.mac-traffic-red').addEventListener('click', e => { e.stopPropagation(); closeWindow(id); });
    w.el.querySelector('.mac-traffic-yellow').addEventListener('click', e => { e.stopPropagation(); minimizeWindow(id); });
    w.el.querySelector('.mac-traffic-green').addEventListener('click', e => { e.stopPropagation(); wiggle(id); });
    makeDraggable(w.el, w.el.querySelector('.mac-window-titlebar'), () => focusWindow(id));
  });

  function makeDraggable(win, handle, onDown) {
    handle.addEventListener('pointerdown', e => {
      if (e.target.closest('.mac-traffic')) return;
      onDown();
      const s = macScale();
      const startX = e.clientX, startY = e.clientY;
      const originLeft = parseFloat(win.style.left), originTop = parseFloat(win.style.top);
      handle.setPointerCapture(e.pointerId);
      function move(ev) {
        const r = macRect();
        const dx = (ev.clientX - startX) / s, dy = (ev.clientY - startY) / s;
        const w = win.offsetWidth, h = win.offsetHeight;
        win.style.left = clamp(originLeft + dx, 0, 1280 - w) + 'px';
        win.style.top = clamp(originTop + dy, 24, 800 - Math.min(40, h * 0.3)) + 'px';
      }
      function up() { handle.removeEventListener('pointermove', move); handle.removeEventListener('pointerup', up); }
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', up, { once: true });
    });
  }
  const clamp = (v, min, max) => Math.min(Math.max(v, min), max);

  // ------------------------------------------------------------------------------------- dock
  $$('.mac-dock-icon[data-app]').forEach(icon => {
    const id = icon.dataset.app;
    icon.addEventListener('click', () => {
      const w = wins.get(id);
      if (w.mode === 'open') { focusWindow(id); wiggle(id); }
      else restoreWindow(id);
    });
  });
  if (!REDUCE_MOTION) {
    dock.addEventListener('pointermove', e => {
      const icons = $$('.mac-dock-icon', dock);
      icons.forEach(icon => {
        const r = icon.getBoundingClientRect();
        const dist = Math.abs(e.clientX - (r.left + r.width / 2));
        const s = Math.max(1, 1.55 - dist / 78);
        icon.style.transform = `scale(${s.toFixed(3)}) translateY(${(-(s - 1) * 14).toFixed(1)}px)`;
      });
    });
    dock.addEventListener('pointerleave', () => $$('.mac-dock-icon', dock).forEach(i => { i.style.transform = ''; }));
  }

  // -------------------------------------------------------------------------------- sound gate
  gateButton.addEventListener('click', () => engine.start());
  engine.on('power', on => {
    if (on) {
      gate.classList.add('is-hidden');
      // Fully collapse after the fade so a translucent panel/backdrop-filter above it
      // never has a hidden-but-still-painted layer to sample from.
      setTimeout(() => { if (gate.classList.contains('is-hidden')) gate.hidden = true; }, 260);
    } else {
      gate.hidden = false;
      gate.classList.remove('is-hidden');
    }
  });

  // ---------------------------------------------------------------------------------- pings
  const chatBody = $('.mac-pings-body');
  CHAT_SEED.forEach(m => appendMessage(m));
  function appendMessage(msg) {
    const row = document.createElement('div');
    row.className = 'mac-chat-msg';
    row.innerHTML = `<span class="mac-chat-from">${escapeHtml(msg.from)}</span><span class="mac-chat-text">${escapeHtml(msg.text)}</span>`;
    chatBody.appendChild(row);
    chatBody.scrollTop = chatBody.scrollHeight;
  }
  function showBanner(msg) {
    const n = document.createElement('div');
    n.className = 'mac-notification';
    n.innerHTML = `<svg class="mac-notification-icon" aria-hidden="true"><use href="assets/stickers.svg#${APP_ICON.pings}"/></svg>
      <div class="mac-notification-body"><div class="mac-notification-top"><b>${escapeHtml(msg.from)}</b><span>now</span></div><div class="mac-notification-text">${escapeHtml(msg.text)}</div></div>`;
    notifications.prepend(n);
    const timer = setTimeout(() => dismiss(), 4000);
    n.addEventListener('click', dismiss);
    function dismiss() {
      clearTimeout(timer);
      n.classList.add('is-leaving');
      n.addEventListener('animationend', () => n.remove(), { once: true });
    }
  }
  engine.on('ping', msg => { appendMessage(msg); showBanner(msg); });

  // ---------------------------------------------------------------------------------- calls
  let activeSpeaker = -1;
  const callTiles = $$('.mac-call-tile');
  engine.on('speaker', index => {
    activeSpeaker = index;
    callTiles.forEach((tile, i) => tile.classList.toggle('is-speaking', i === index));
  });
  $('.mac-window[data-window="calls"] .mac-call-leave').addEventListener('click', () => { engine.setPlaying('calls', false); closeWindow('calls'); });

  // ---------------------------------------------------------------------------------- music
  const musicPlayBtn = $('.mac-music-play');
  musicPlayBtn.addEventListener('click', () => engine.setPlaying('music', !state.playing.music));
  const musicBars = $$('.mac-music-bars .bar');
  const musicProgress = $('.mac-music-progress-fill');
  const musicTime = $('.mac-music-time');
  let musicElapsed = 41;

  // -------------------------------------------------------------------------------- browser
  const browserPlayBtn = $('.mac-browser-play');
  browserPlayBtn.addEventListener('click', () => engine.setPlaying('browser', !state.playing.browser));
  const rainCanvas = $('.mac-rain-canvas');
  const rainCtx = rainCanvas.getContext('2d');
  rainCanvas.width = 548 * 2; rainCanvas.height = 220 * 2;
  const drops = Array.from({ length: 90 }, () => randomDrop());
  function randomDrop() { return { x: Math.random() * rainCanvas.width, y: Math.random() * rainCanvas.height, len: 14 + Math.random() * 22, speed: 6 + Math.random() * 8 }; }

  // --------------------------------------------------------------------------- other app play/stop generic (compact list + quit re-plug)
  $$('.mac-app-toggle').forEach(btn => btn.addEventListener('click', () => engine.setPlaying(btn.dataset.app, !state.playing[btn.dataset.app])));

  // -------------------------------------------------------------------------------- devices
  const hp = $('.mac-headphones');
  const airpods = $('.mac-airpods');
  hp.addEventListener('click', () => state.setConnected('headphones', !state.connected.headphones));
  airpods.addEventListener('click', () => state.setConnected('airpods', !state.connected.airpods));

  // -------------------------------------------------------------------------------- checklist
  const goals = { pingsDown: false, musicToAirpods: false, unpluggedWhilePlaying: false, toggledStill: false };
  let lastAudible = snapshotAudible();
  let sawStillOff = false;
  function snapshotAudible() {
    const out = {};
    for (const a of APPS) out[a.id] = state.audible(a.id);
    return out;
  }
  function watchChecklist(prevConnectedHeadphones) {
    if (state.prefs.pings.muted || state.prefs.pings.volume < 0.5) goals.pingsDown = true;
    if (state.prefs.music.output === 'airpods') goals.musicToAirpods = true;
    if (prevConnectedHeadphones && !state.connected.headphones) {
      const wasRouted = Object.keys(lastAudible).some(id => lastAudible[id].device === 'headphones' && state.playing[id]);
      if (wasRouted) goals.unpluggedWhilePlaying = true;
    }
    if (!state.enabled) sawStillOff = true;
    if (state.enabled && sawStillOff) goals.toggledStill = true;
    lastAudible = snapshotAudible();
  }

  // -------------------------------------------------------------------------------- clock
  function tickClock() {
    const now = new Date();
    const day = now.toLocaleDateString(undefined, { weekday: 'short' });
    const date = now.getDate();
    const month = now.toLocaleDateString(undefined, { month: 'short' });
    let h = now.getHours(); const m = String(now.getMinutes()).padStart(2, '0');
    const ap = h >= 12 ? 'PM' : 'AM'; h = h % 12 || 12;
    clockEl.textContent = `${day} ${date} ${month}  ${h}:${m} ${ap}`;
  }
  tickClock();
  setInterval(tickClock, 15000);

  // ----------------------------------------------------------------------------------- render
  let prevConnected = { ...state.connected };
  function render() {
    // dock running dots
    APPS.forEach(a => {
      const dot = dock.querySelector(`.mac-dock-icon[data-app="${a.id}"] .mac-dock-dot`);
      if (dot) dot.classList.toggle('is-on', !!state.playing[a.id]);
      const win = wins.get(a.id);
      if (win) win.el.classList.toggle('is-hidden', win.mode !== 'open');
    });
    // status item
    syncStatusStill();
    // music
    const musicPlaying = state.playing.music;
    musicPlayBtn.setAttribute('aria-label', musicPlaying ? 'Pause' : 'Play');
    musicPlayBtn.classList.toggle('is-playing', musicPlaying);
    // browser
    const browserPlaying = state.playing.browser;
    browserPlayBtn.setAttribute('aria-label', browserPlaying ? 'Pause' : 'Play');
    browserPlayBtn.classList.toggle('is-playing', browserPlaying);
    // compact now-playing list
    $$('.mac-app-toggle').forEach(btn => {
      const id = btn.dataset.app;
      btn.textContent = state.playing[id] ? 'Stop' : 'Play';
      btn.closest('.mac-np-row')?.classList.toggle('is-playing', !!state.playing[id]);
    });
    // devices
    hp.classList.toggle('is-connected', state.connected.headphones);
    hp.querySelector('.mac-device-label').textContent = state.connected.headphones ? 'Plugged in' : 'Unplugged';
    airpods.classList.toggle('is-connected', state.connected.airpods);
    airpods.querySelector('.mac-device-label').textContent = state.connected.airpods ? 'Connected' : 'In case';
    // checklist
    watchChecklist(prevConnected.headphones);
    prevConnected = { ...state.connected };
    setGoal('pings-down', goals.pingsDown);
    setGoal('music-airpods', goals.musicToAirpods);
    setGoal('unplug-playing', goals.unpluggedWhilePlaying);
    setGoal('toggle-still', goals.toggledStill);
    if (ccPanel.classList.contains('is-open')) renderOutputs();
  }
  function setGoal(key, done) {
    const li = $(`.mac-sticky-item[data-goal="${key}"]`);
    li.classList.toggle('is-done', done);
  }
  state.subscribe(render);

  // ------------------------------------------------------------------------------ animation loop
  let visible = true;
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; }, { threshold: 0.01 }).observe(stage);
  document.addEventListener('visibilitychange', () => {});
  let last = performance.now();
  function frame(t) {
    requestAnimationFrame(frame);
    const dt = Math.min(0.05, (t - last) / 1000); last = t;
    if (!visible || document.hidden) return;

    // wallpaper swell
    if (!REDUCE_MOTION && wallpaperWave) {
      const amp = engine.masterLevel();
      wallpaperWave.style.transform = `translateY(${(-amp * 18).toFixed(2)}px)`;
    }
    // music visualizer + progress
    const peak = engine.sourcePeak('music');
    musicBars.forEach((bar, i) => {
      const base = 0.2 + ((i * 37) % 10) / 10 * 0.5;
      const wob = state.playing.music ? Math.sin(t / 260 + i) * 0.15 : 0;
      const h = Math.max(0.06, Math.min(1, base * (0.35 + peak * 1.3) + wob * peak));
      bar.style.height = (h * 100).toFixed(1) + '%';
    });
    if (state.playing.music) {
      musicElapsed = (musicElapsed + dt) % TRACK_LEN;
      const pct = (musicElapsed / TRACK_LEN) * 100;
      musicProgress.style.width = pct.toFixed(2) + '%';
      musicTime.textContent = fmtTime(musicElapsed) + ' / ' + fmtTime(TRACK_LEN);
    }
    // calls bars
    if (activeSpeaker >= 0) {
      const callPeak = engine.sourcePeak('calls');
      const tile = callTiles[activeSpeaker];
      if (tile) {
        const bars = tile.querySelectorAll('.mac-call-bar');
        bars.forEach((b, i) => { b.style.height = (20 + Math.sin(t / 90 + i * 1.7) * 10 * (0.3 + callPeak) + callPeak * 40).toFixed(1) + '%'; });
      }
    }
    // rain canvas
    if (state.playing.browser) {
      rainCtx.clearRect(0, 0, rainCanvas.width, rainCanvas.height);
      rainCtx.strokeStyle = 'rgba(255,255,255,0.55)';
      rainCtx.lineWidth = 2;
      for (const d of drops) {
        rainCtx.beginPath(); rainCtx.moveTo(d.x, d.y); rainCtx.lineTo(d.x - 3, d.y + d.len); rainCtx.stroke();
        d.y += d.speed * (dt * 60); d.x -= 0.6 * (dt * 60);
        if (d.y > rainCanvas.height) { d.y = -20; d.x = Math.random() * rainCanvas.width; }
      }
    }
  }
  requestAnimationFrame(frame);

  render();
  refreshControlCenter();
}

function fmtTime(s) { const m = Math.floor(s / 60), r = Math.floor(s % 60); return `${m}:${String(r).padStart(2, '0')}`; }
function escapeHtml(s) { return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

function markup(uid) {
  return `
  <div class="mac-stage">
    <div class="mac-laptop">
      <div class="mac-bezel">
        <div class="mac-scale-wrap">
          <div class="mac" data-appearance="light">
            <div class="mac-notch" aria-hidden="true"></div>
            <div class="mac-wallpaper" aria-hidden="true">
              <svg class="mac-wave-svg" viewBox="0 0 1280 800" preserveAspectRatio="none">
                <path class="mac-wave-back" d="M0,520 C220,470 420,560 640,520 C880,470 1080,560 1280,510 L1280,800 L0,800 Z"/>
                <path class="mac-wave-mid" d="M0,600 C240,560 460,650 700,600 C920,555 1120,640 1280,600 L1280,800 L0,800 Z"/>
                <g class="mac-wave-main">
                  <path class="mac-wave-front" d="M0,690 C260,650 480,730 720,690 C960,650 1140,730 1280,690 L1280,800 L0,800 Z"/>
                </g>
              </svg>
            </div>

            <div class="mac-menubar">
              <div class="mac-menubar-left">
                <span class="mac-apple" aria-hidden="true">
                  <svg viewBox="0 0 24 24"><path fill="currentColor" d="M16.5 3.2c.1 1-.3 2-.9 2.7-.6.7-1.6 1.3-2.6 1.2-.1-1 .4-2 1-2.7.6-.8 1.7-1.3 2.5-1.2zM19.8 17c-.5 1.1-.8 1.6-1.4 2.6-.9 1.4-2.2 3.1-3.8 3.1-1.4 0-1.8-.9-3.7-.9s-2.4.9-3.7.9c-1.6 0-2.8-1.5-3.7-2.9-2.6-4-2.9-8.6-1.3-11 1.1-1.7 2.9-2.7 4.6-2.7 1.7 0 2.8 1 4.2 1s2.2-1 4.2-1c1.6 0 3.2.9 4.3 2.4-3.8 2.1-3.2 7.3.3 8.5z"/></svg>
                </span>
                <span class="mac-menubar-appname"></span>
                ${Object.keys(MENUS).map(name => `
                  <span class="mac-menu">
                    <button type="button" class="mac-menu-item" data-menu="${name}" aria-haspopup="true" aria-expanded="false">${name}</button>
                    <div class="mac-menu-dropdown" role="menu">
                      ${MENUS[name].map(item => item === '—' ? '<div class="mac-menu-sep"></div>' : `<div class="mac-menu-entry" role="menuitem" aria-disabled="true">${item}</div>`).join('')}
                    </div>
                  </span>`).join('')}
              </div>
              <div class="mac-menubar-right">
                <button type="button" class="mac-status mac-status-still" aria-label="Still" aria-haspopup="true">
                  <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="2.6" height="14" rx="1.3" fill="currentColor"/><rect x="10.7" y="5" width="2.6" height="14" rx="1.3" fill="currentColor"/><rect x="17.4" y="5" width="2.6" height="14" rx="1.3" fill="currentColor"/><circle cx="5.3" cy="15" r="2" fill="currentColor" stroke="var(--paper-io,#fff)" stroke-width="0"/><circle cx="12" cy="9" r="2" fill="currentColor"/><circle cx="18.7" cy="12" r="2" fill="currentColor"/></svg>
                </button>
                <button type="button" class="mac-status mac-status-cc" aria-label="Control Center" aria-haspopup="true" aria-expanded="false">
                  <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="3" width="7.5" height="7.5" rx="2" fill="currentColor"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="2" fill="currentColor" opacity=".55"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="2" fill="currentColor" opacity=".55"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="2" fill="currentColor"/></svg>
                </button>
                <span class="mac-status mac-status-wifi" aria-hidden="true">
                  <svg viewBox="0 0 24 24"><path d="M12 17.2a1.4 1.4 0 100 2.8 1.4 1.4 0 000-2.8zM8.5 14.3a5 5 0 017 0l-1.4 1.5a3 3 0 00-4.2 0zM5.5 11.2a9.3 9.3 0 0113 0l-1.4 1.5a7.3 7.3 0 00-10.2 0z" fill="currentColor"/></svg>
                </span>
                <span class="mac-status mac-status-battery" aria-hidden="true">
                  <svg viewBox="0 0 26 14"><rect x="1" y="1.5" width="21" height="11" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.2"/><rect x="3" y="3.3" width="14" height="7.4" rx="1" fill="currentColor"/><rect x="23" y="4.5" width="2" height="5" rx="1" fill="currentColor"/></svg>
                  <span class="mac-battery-pct">78%</span>
                </span>
                <span class="mac-clock"></span>
              </div>
            </div>

            <div class="mac-controlcenter" role="dialog" aria-label="Control Center">
              <div class="mac-cc-grid">
                <div class="mac-cc-tile" data-decorative>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 17.2a1.4 1.4 0 100 2.8 1.4 1.4 0 000-2.8zM8.5 14.3a5 5 0 017 0l-1.4 1.5a3 3 0 00-4.2 0zM5.5 11.2a9.3 9.3 0 0113 0l-1.4 1.5a7.3 7.3 0 00-10.2 0z" fill="currentColor"/></svg>
                  <span>Wi-Fi</span>
                </div>
                <div class="mac-cc-tile" data-decorative>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2v9.5L8.5 8M12 11.5L15.5 8M12 11.5V22M8.5 15.5L12 19l3.5-3.5" stroke="currentColor" stroke-width="1.6" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
                  <span>Bluetooth</span>
                </div>
                <div class="mac-cc-tile mac-cc-appearance" data-decorative aria-pressed="false">
                  <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="5" fill="currentColor"/><g stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.5 4.5l2 2M17.5 17.5l2 2M19.5 4.5l-2 2M6.5 17.5l-2 2"/></g></svg>
                  <span>Appearance</span>
                </div>
                <div class="mac-cc-tile" data-decorative>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.4 15.3A9 9 0 018.7 3.6 9 9 0 1020.4 15.3z" fill="currentColor"/></svg>
                  <span>Focus</span>
                </div>
              </div>
              <div class="mac-cc-sound">
                <span class="mac-cc-sound-label">Sound</span>
                <input type="range" min="0" max="100" value="80" aria-label="System volume">
              </div>
              <div class="mac-cc-outputs" role="listbox" aria-label="Output device"></div>
            </div>

            <div class="mac-windows-layer">
              ${LAYOUT.map(w => windowMarkup(w)).join('')}
            </div>

            <div class="mac-dock">
              <div class="mac-dock-icon mac-dock-finder" aria-hidden="true" title="Finder">
                <svg viewBox="0 0 64 64"><rect x="2" y="2" width="60" height="60" rx="16" fill="#ffd731" stroke="#000" stroke-width="2"/><circle cx="24" cy="28" r="4" fill="#000"/><circle cx="40" cy="28" r="4" fill="#000"/><path d="M20,40 Q32,50 44,40" stroke="#000" stroke-width="3.4" fill="none" stroke-linecap="round"/></svg>
              </div>
              <div class="mac-dock-sep"></div>
              ${APPS.map(a => `
                <button type="button" class="mac-dock-icon" data-app="${a.id}" aria-label="${a.name}">
                  <svg aria-hidden="true"><use href="assets/stickers.svg#${APP_ICON[a.id]}"/></svg>
                  <span class="mac-dock-dot" aria-hidden="true"></span>
                </button>`).join('')}
              <div class="mac-dock-sep"></div>
              <div class="mac-dock-icon mac-dock-trash" aria-hidden="true" title="Trash">
                <svg viewBox="0 0 24 24"><path d="M5 7h14M9 7V5.5A1.5 1.5 0 0110.5 4h3A1.5 1.5 0 0115 5.5V7M7 7l1 13h8l1-13" stroke="currentColor" stroke-width="1.6" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
              </div>
            </div>

            <div class="mac-notifications" aria-live="polite"></div>
            <div class="mac-panel-host"></div>

            <div class="mac-now-playing">
              <h3>Now playing</h3>
              ${APPS.map(a => `
                <div class="mac-np-row" data-app="${a.id}">
                  <svg class="mac-np-icon" aria-hidden="true"><use href="assets/stickers.svg#${APP_ICON[a.id]}"/></svg>
                  <span class="mac-np-name">${a.name}</span>
                  <button type="button" class="mac-app-toggle" data-app="${a.id}">Play</button>
                </div>`).join('')}
            </div>

            <div class="mac-gate">
              <div class="mac-gate-card">
                <svg class="mac-gate-icon" aria-hidden="true"><use href="assets/stickers.svg#speaker"/></svg>
                <button type="button" class="mac-gate-button">Turn on sound</button>
                <p class="mac-gate-hint">Four apps will start playing at once. Use Still to calm them down.</p>
              </div>
            </div>
          </div>
        </div>
      </div>
      <div class="mac-hinge"></div>
      <div class="mac-base"></div>
    </div>

    <div class="mac-table">
      <button type="button" class="mac-headphones" aria-label="Studio Headphones">
        <span class="mac-cable" aria-hidden="true">
          <svg class="mac-cord" viewBox="0 0 120 100"><path d="M112,92 C96,70 104,52 80,50 C52,48 60,20 30,22" fill="none" stroke="#000" stroke-width="3.2" stroke-linecap="round"/></svg>
          <svg class="mac-plug" aria-hidden="true"><use href="assets/stickers.svg#plug"/></svg>
        </span>
        <svg class="mac-sticker-svg" aria-hidden="true"><use href="assets/stickers.svg#headphones"/></svg>
        <span class="mac-device-label">Plugged in</span>
      </button>
      <button type="button" class="mac-airpods" aria-label="AirPods Pro">
        <svg class="mac-sticker-svg" aria-hidden="true"><use href="assets/stickers.svg#airpods"/></svg>
        <span class="mac-device-label">In case</span>
      </button>

      <div class="mac-sticky">
        <h3>Try this</h3>
        <ul>
          <li class="mac-sticky-item" data-goal="pings-down"><span class="mac-sticky-check" aria-hidden="true"><svg><use href="assets/stickers.svg#check"/></svg></span><span>Turn Pings down</span></li>
          <li class="mac-sticky-item" data-goal="music-airpods"><span class="mac-sticky-check" aria-hidden="true"><svg><use href="assets/stickers.svg#check"/></svg></span><span>Send Music to AirPods Pro</span></li>
          <li class="mac-sticky-item" data-goal="unplug-playing"><span class="mac-sticky-check" aria-hidden="true"><svg><use href="assets/stickers.svg#check"/></svg></span><span>Unplug the headphones mid-song</span></li>
          <li class="mac-sticky-item" data-goal="toggle-still"><span class="mac-sticky-check" aria-hidden="true"><svg><use href="assets/stickers.svg#check"/></svg></span><span>Switch Still off, then back on</span></li>
        </ul>
      </div>
    </div>
  </div>`;
}

function windowMarkup(w) {
  return `
  <div class="mac-window mac-window--${w.id}" data-window="${w.id}" role="group" aria-label="${w.title}">
    <div class="mac-window-titlebar">
      <span class="mac-traffic">
        <button type="button" class="mac-traffic-red" aria-label="Close ${w.title}"></button>
        <button type="button" class="mac-traffic-yellow" aria-label="Minimize ${w.title}"></button>
        <button type="button" class="mac-traffic-green" aria-label="Zoom ${w.title}"></button>
      </span>
      <span class="mac-window-title">${w.title}</span>
    </div>
    <div class="mac-window-body">${windowBody(w.id)}</div>
  </div>`;
}

function windowBody(id) {
  if (id === 'music') return `
    <div class="mac-music">
      <div class="mac-music-art" style="background:${APP_COLOR.music}"><svg aria-hidden="true"><use href="assets/stickers.svg#cassette"/></svg></div>
      <div class="mac-music-info">
        <div class="mac-music-title">Late Night Drive</div>
        <div class="mac-music-subtitle">Demo Tape</div>
        <div class="mac-music-bars">${Array.from({ length: 24 }, () => '<span class="bar"></span>').join('')}</div>
        <div class="mac-music-transport">
          <button type="button" class="mac-music-play" aria-label="Play"><svg class="ic-play" viewBox="0 0 24 24"><path d="M8 5l12 7-12 7z" fill="currentColor"/></svg><svg class="ic-pause" viewBox="0 0 24 24"><rect x="6" y="5" width="4" height="14" fill="currentColor"/><rect x="14" y="5" width="4" height="14" fill="currentColor"/></svg></button>
          <div class="mac-music-progress"><div class="mac-music-progress-fill"></div></div>
          <span class="mac-music-time">0:41 / 3:42</span>
        </div>
      </div>
    </div>`;
  if (id === 'browser') return `
    <div class="mac-browser">
      <div class="mac-browser-tabs"><span class="mac-browser-tab is-active">Rain sounds · 10 hours</span></div>
      <div class="mac-browser-urlbar">rainfor.work/10-hours</div>
      <div class="mac-browser-video">
        <canvas class="mac-rain-canvas"></canvas>
        <button type="button" class="mac-browser-play" aria-label="Play"><svg class="ic-play" viewBox="0 0 24 24"><path d="M8 5l12 7-12 7z" fill="currentColor"/></svg><svg class="ic-pause" viewBox="0 0 24 24"><rect x="6" y="5" width="4" height="14" fill="currentColor"/><rect x="14" y="5" width="4" height="14" fill="currentColor"/></svg></button>
      </div>
    </div>`;
  if (id === 'calls') return `
    <div class="mac-calls">
      <div class="mac-calls-title">Weekly sync</div>
      <div class="mac-calls-grid">
        ${CALLERS.map(c => `
          <div class="mac-call-tile">
            <span class="mac-call-avatar" style="background:${c.color}">${c.initials}</span>
            <span class="mac-call-name">${c.name}</span>
            <span class="mac-call-bars" aria-hidden="true">${Array.from({ length: 5 }, () => '<span class="mac-call-bar"></span>').join('')}</span>
          </div>`).join('')}
      </div>
      <div class="mac-calls-toolbar">
        <button type="button" class="mac-calls-deco" aria-label="Mute microphone"><svg viewBox="0 0 24 24"><path d="M12 15a3 3 0 003-3V6a3 3 0 10-6 0v6a3 3 0 003 3zm5-3a5 5 0 01-10 0M12 18v3" stroke="currentColor" stroke-width="1.6" fill="none" stroke-linecap="round"/></svg></button>
        <button type="button" class="mac-calls-deco" aria-label="Turn camera off"><svg viewBox="0 0 24 24"><rect x="3" y="7" width="12" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M15 10l6-3v10l-6-3z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg></button>
        <button type="button" class="mac-call-leave">Leave</button>
      </div>
    </div>`;
  return `
    <div class="mac-pings">
      <div class="mac-pings-body"></div>
    </div>`;
}
