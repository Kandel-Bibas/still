// The Still menu bar panel — a pixel replica of Sources/Still/MixerPanel.swift,
// driven by the demo's StillState/AudioEngine. See MixerPanel.swift for the
// layout this mirrors: header, a Favorites/Apps row list, and a footer.

import { APPS } from './state.js';
import { meterLevel } from './audio.js';

// Matches PanelMetrics in MixerPanel.swift.
const CONTROL_COLUMN = 26;
const CONTROL_SPACING = 10;
const PERCENT_WIDTH = 34;

const PATHS = {
  speakerCone: '<path d="M1.2 6.1H4.3L8.4 2.6V13.4L4.3 9.9H1.2Z" fill="currentColor"/>',
  speakerWaves:
    '<path d="M10.6 5.4c.85.72 1.35 1.6 1.35 2.6s-.5 1.88-1.35 2.6" fill="none" stroke="currentColor" stroke-width="1.15" stroke-linecap="round"/>' +
    '<path d="M12.6 3.5c1.4 1.2 2.25 2.7 2.25 4.5s-.85 3.3-2.25 4.5" fill="none" stroke="currentColor" stroke-width="1.15" stroke-linecap="round"/>',
  speakerSlash:
    '<path d="M10.6 4.8L15 11.2M15 4.8L10.6 11.2" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round"/>',
  chevron: '<path d="M4.2 6.2L8 10L11.8 6.2" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>',
  check: '<path d="M3.3 8.6L6.6 11.9L12.8 4.6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
  ellipsis:
    '<circle cx="3.6" cy="8" r="1.35" fill="currentColor"/><circle cx="8" cy="8" r="1.35" fill="currentColor"/><circle cx="12.4" cy="8" r="1.35" fill="currentColor"/>',
  waveform:
    '<line x1="2" y1="6" x2="2" y2="10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>' +
    '<line x1="5.2" y1="3.5" x2="5.2" y2="12.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>' +
    '<line x1="8.4" y1="1.5" x2="8.4" y2="14.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>' +
    '<line x1="11.6" y1="3.5" x2="11.6" y2="12.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>' +
    '<line x1="14.8" y1="6" x2="14.8" y2="10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
};

function speakerIconPaths(muted) {
  return PATHS.speakerCone + (muted ? PATHS.speakerSlash : PATHS.speakerWaves);
}

function pinIconPaths(filled) {
  const head = filled
    ? '<rect x="5.6" y="1.8" width="4.8" height="6.6" rx="1.1" fill="currentColor"/>'
    : '<rect x="5.6" y="1.8" width="4.8" height="6.6" rx="1.1" fill="none" stroke="currentColor" stroke-width="1.1"/>';
  const needle = '<line x1="8" y1="8.4" x2="8" y2="14.2" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>';
  return `<g transform="rotate(45 8 8)">${head}${needle}</g>`;
}

function icon(paths, size = 12) {
  const span = document.createElement('span');
  span.className = 'still-icon';
  span.style.width = `${size}px`;
  span.style.height = `${size}px`;
  span.setAttribute('aria-hidden', 'true');
  span.innerHTML = `<svg viewBox="0 0 16 16" width="${size}" height="${size}">${paths}</svg>`;
  return span;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function createPanel({ state, engine, onClose }) {
  const element = document.createElement('div');
  element.className = 'still-panel';
  element.setAttribute('role', 'dialog');
  element.setAttribute('aria-label', 'Still');

  const inner = document.createElement('div');
  inner.className = 'still-panel-inner';

  // ---------------- header ----------------

  const header = el('div', 'still-header');
  const headerTop = el('div', 'still-header-top');
  const title = el('span', 'still-title', 'Still');
  const headerSpacer = el('div', 'still-spacer');

  const switchBtn = document.createElement('button');
  switchBtn.type = 'button';
  switchBtn.className = 'still-switch';
  switchBtn.setAttribute('role', 'switch');
  switchBtn.setAttribute('aria-label', 'Per-app audio control');
  switchBtn.title =
    'Turning off Still restores each app’s original volume and output. Muted apps may become audible.';
  switchBtn.appendChild(el('span', 'still-switch-knob'));
  switchBtn.addEventListener('click', () => state.setEnabled(!state.enabled));

  headerTop.append(title, headerSpacer, switchBtn);

  const headerSub = el('div', 'still-header-sub');
  const headerSubIcon = icon(speakerIconPaths(false), 10);
  const deviceNameEl = el('span', 'still-device-name');
  headerSub.append(headerSubIcon, deviceNameEl);

  header.append(headerTop, headerSub);

  const sepTop = el('div', 'still-separator');
  const sepBottom = el('div', 'still-separator');

  // ---------------- list shell ----------------

  const list = el('div', 'still-list');

  const enableNotice = el('div', 'still-enable-notice');
  enableNotice.hidden = true;
  enableNotice.append(
    el('div', 'still-enable-title', 'App volume and output'),
    el(
      'div',
      'still-enable-body',
      'Set each app’s volume and choose where it plays. macOS will ask for System Audio Recording access so Still can control your audio.'
    ),
    el('div', 'still-enable-foot', 'Audio stays on this Mac and is never saved.')
  );
  const enableBtn = document.createElement('button');
  enableBtn.type = 'button';
  enableBtn.className = 'still-enable-btn';
  enableBtn.textContent = 'Enable Still';
  enableBtn.addEventListener('click', () => state.setEnabled(true));
  enableNotice.appendChild(enableBtn);

  const emptyState = el('div', 'still-empty');
  emptyState.hidden = true;
  const emptyShowBtn = document.createElement('button');
  emptyShowBtn.type = 'button';
  emptyShowBtn.className = 'still-link';
  emptyShowBtn.textContent = 'Show inactive apps';
  emptyShowBtn.addEventListener('click', () => {
    showAllApps = true;
    render();
  });
  emptyState.append(
    icon(PATHS.waveform, 22),
    el('div', 'still-empty-title', 'No apps playing audio'),
    el('div', 'still-empty-body', 'Play something and its volume controls appear here.'),
    emptyShowBtn
  );

  const sections = el('div', 'still-sections');
  sections.hidden = true;

  list.append(enableNotice, emptyState, sections);

  // ---------------- footer ----------------

  const footer = el('div', 'still-footer');

  const settingsBtn = document.createElement('button');
  settingsBtn.type = 'button';
  settingsBtn.className = 'still-settings-btn';
  settingsBtn.textContent = 'Still Settings…';
  settingsBtn.setAttribute('aria-label', 'Still settings');
  settingsBtn.title = 'Settings… (⌘,)';
  settingsBtn.addEventListener('click', () => showToast('Settings open in the real app.'));

  const footerSpacer = el('div', 'still-spacer');

  const ellipsisWrap = el('div', 'still-ellipsis-wrap');
  const ellipsisBtn = document.createElement('button');
  ellipsisBtn.type = 'button';
  ellipsisBtn.className = 'still-ellipsis-btn';
  ellipsisBtn.setAttribute('aria-label', 'More options');
  ellipsisBtn.appendChild(icon(PATHS.ellipsis, 12));
  ellipsisBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    openEllipsisMenu();
  });
  ellipsisWrap.appendChild(ellipsisBtn);

  footer.append(settingsBtn, footerSpacer, ellipsisWrap);

  inner.append(header, sepTop, list, sepBottom, footer);

  const toastEl = el('div', 'still-toast');
  toastEl.setAttribute('role', 'status');

  element.append(inner, toastEl);

  // ---------------- local UI state ----------------

  let showAllApps = false;
  let openFlag = false;
  let unsubscribe = null;
  let lastSignature = null;
  let toastTimer = null;
  let rafId = null;
  const rowElements = new Map();
  const meterTargets = new Set();
  const meterPrev = Object.create(null);

  // ---------------- rows ----------------

  function visibleApps() {
    return APPS.filter((a) => showAllApps || state.playing[a.id] || state.prefs[a.id].pinned);
  }

  function computeSignature(vis) {
    return `${state.enabled}|${showAllApps}|${vis.map((a) => `${a.id}:${state.prefs[a.id].pinned ? 'f' : 'a'}`).join(',')}`;
  }

  function buildRow(appId) {
    const app = state.app(appId);
    const row = el('div', 'still-row');

    const top = el('div', 'still-row-top');
    const iconEl = el('div', 'still-row-icon');
    iconEl.innerHTML = `<svg viewBox="0 0 26 26" aria-hidden="true"><use href="assets/stickers.svg#app-${appId}"></use></svg>`;

    const info = el('div', 'still-row-info');
    const nameEl = el('div', 'still-row-name', app.name);

    const outputBtn = document.createElement('button');
    outputBtn.type = 'button';
    outputBtn.className = 'still-output-btn';
    const outputLabelEl = el('span', 'still-output-label');
    outputBtn.append(outputLabelEl, icon(PATHS.chevron, 9));
    outputBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      openOutputMenu(appId, outputBtn);
    });
    info.append(nameEl, outputBtn);

    const spacer = el('div', 'still-spacer');

    const pinBtn = document.createElement('button');
    pinBtn.type = 'button';
    pinBtn.className = 'still-pin-btn';
    pinBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      state.togglePin(appId);
    });

    top.append(iconEl, info, spacer, pinBtn);

    const controls = el('div', 'still-row-controls');

    const muteBtn = document.createElement('button');
    muteBtn.type = 'button';
    muteBtn.className = 'still-mute-btn';
    muteBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      state.toggleMute(appId);
    });

    const slider = document.createElement('input');
    slider.type = 'range';
    slider.className = 'still-slider';
    slider.min = '0';
    slider.max = '100';
    slider.step = '1';
    slider.addEventListener('input', () => {
      state.setVolume(appId, Number(slider.value) / 100);
    });

    const percentEl = el('span', 'still-percent');

    controls.append(muteBtn, slider, percentEl);

    const meter = el('div', 'still-meter');
    meter.hidden = true;
    const meterFill = el('div', 'still-meter-fill');
    meter.appendChild(meterFill);

    const status = el('div', 'still-status');
    status.hidden = true;
    const statusIcon = document.createElement('span');
    const statusText = document.createElement('span');
    status.append(statusIcon, statusText);

    row.append(top, controls, meter, status);

    const refs = {
      root: row,
      iconEl,
      outputBtn,
      outputLabelEl,
      pinBtn,
      controls,
      muteBtn,
      slider,
      percentEl,
      meter,
      meterFill,
      status,
      statusIcon,
      statusText,
    };
    rowElements.set(appId, refs);
    updateRow(appId, refs);
    return row;
  }

  function updateRow(appId, refs) {
    refs = refs || rowElements.get(appId);
    if (!refs) return;
    const app = state.app(appId);
    const prefs = state.prefs[appId];
    const active = !!state.playing[appId];
    const pinned = !!prefs.pinned;
    const muted = !!prefs.muted;
    const status = state.status(appId);
    const outputLabel = state.outputLabel(appId);

    refs.iconEl.classList.toggle('is-inactive', !active);

    refs.outputLabelEl.textContent = outputLabel;
    refs.outputBtn.setAttribute('aria-label', `Output for ${app.name}: ${outputLabel}`);
    refs.outputBtn.title = `Choose the output for ${app.name}`;

    refs.pinBtn.classList.toggle('is-pinned', pinned);
    refs.pinBtn.innerHTML = '';
    refs.pinBtn.appendChild(icon(pinIconPaths(pinned), 11));
    refs.pinBtn.setAttribute('aria-label', pinned ? `Unpin ${app.name}` : `Pin ${app.name}`);
    refs.pinBtn.title = pinned ? 'Remove from Favorites' : 'Keep in Favorites';

    refs.muteBtn.innerHTML = '';
    refs.muteBtn.appendChild(icon(speakerIconPaths(muted), 11));
    refs.muteBtn.setAttribute('aria-label', `${muted ? 'Unmute' : 'Mute'} ${app.name}`);
    refs.muteBtn.title = muted ? 'Unmute' : 'Mute';

    const percent = Math.round(prefs.volume * 100);
    if (document.activeElement !== refs.slider) refs.slider.value = String(percent);
    refs.slider.style.setProperty('--fill', `${percent}%`);
    refs.slider.setAttribute('aria-label', `${app.name} volume`);
    refs.slider.setAttribute('aria-valuetext', `${percent} percent${muted ? ', muted' : ''}`);

    refs.percentEl.textContent = `${percent}%`;

    refs.controls.classList.toggle('is-muted', muted);

    const showMeter = status.kind === 'managed' && !muted;
    refs.meter.hidden = !showMeter;
    if (!showMeter) refs.meterFill.style.transform = 'scaleX(0)';

    const showStatus = status.label !== '';
    refs.status.hidden = !showStatus;
    if (showStatus) {
      refs.status.classList.toggle('is-quiet', status.kind === 'inactive');
      refs.statusIcon.innerHTML = '';
      if (status.kind === 'waiting') {
        refs.statusIcon.appendChild(icon(speakerIconPaths(true), 9));
      }
      refs.statusText.textContent = status.label;
    }
  }

  function buildSection(title, apps) {
    const section = el('div', 'still-section');
    if (title) section.appendChild(el('div', 'still-section-title', title));
    for (const app of apps) section.appendChild(buildRow(app.id));
    return section;
  }

  function rebuildList(vis) {
    sections.innerHTML = '';
    rowElements.clear();
    const favorites = vis.filter((a) => state.prefs[a.id].pinned);
    const others = vis.filter((a) => !state.prefs[a.id].pinned);
    const bothNonEmpty = favorites.length > 0 && others.length > 0;
    if (favorites.length) sections.appendChild(buildSection(bothNonEmpty ? 'Favorites' : null, favorites));
    if (others.length) sections.appendChild(buildSection(bothNonEmpty ? 'Apps' : null, others));
  }

  function updateList(vis) {
    for (const app of vis) updateRow(app.id);
  }

  function recomputeMeterTargets(vis) {
    meterTargets.clear();
    for (const app of vis) {
      const status = state.status(app.id);
      if (status.kind === 'managed' && !state.prefs[app.id].muted) meterTargets.add(app.id);
    }
  }

  // ---------------- render ----------------

  function updateHeader() {
    switchBtn.setAttribute('aria-checked', String(state.enabled));
    const device = state.device(state.defaultDevice);
    deviceNameEl.textContent = device ? device.name : '';
    headerSub.title = device ? device.name : '';
  }

  function render() {
    updateHeader();

    if (!state.enabled) {
      enableNotice.hidden = false;
      emptyState.hidden = true;
      sections.hidden = true;
      lastSignature = null;
      meterTargets.clear();
      return;
    }
    enableNotice.hidden = true;

    const vis = visibleApps();
    if (vis.length === 0) {
      emptyState.hidden = false;
      sections.hidden = true;
      emptyShowBtn.hidden = showAllApps;
      lastSignature = null;
      meterTargets.clear();
      return;
    }
    emptyState.hidden = true;
    sections.hidden = false;

    const signature = computeSignature(vis);
    if (signature !== lastSignature) {
      rebuildList(vis);
      lastSignature = signature;
    } else {
      updateList(vis);
    }
    recomputeMeterTargets(vis);
  }

  // ---------------- popup menus ----------------

  let activeMenu = null;

  function closeAnyMenu() {
    if (!activeMenu) return;
    activeMenu.cleanup();
    activeMenu.el.remove();
    activeMenu = null;
  }

  function positionMenu(menu, anchorEl, align) {
    const panelRect = element.getBoundingClientRect();
    const anchorRect = anchorEl.getBoundingClientRect();
    menu.style.top = `${anchorRect.bottom - panelRect.top + 3}px`;
    if (align === 'right') {
      menu.style.right = `${panelRect.right - anchorRect.right}px`;
      menu.style.left = 'auto';
    } else {
      menu.style.left = `${anchorRect.left - panelRect.left}px`;
    }
  }

  function openPopupMenu(anchorEl, align, buildItems) {
    closeAnyMenu();
    const menu = el('div', 'still-menu');
    menu.setAttribute('role', 'menu');
    buildItems(menu);
    element.appendChild(menu);
    positionMenu(menu, anchorEl, align);

    const items = Array.from(menu.querySelectorAll('.still-menu-item'));
    let idx = Math.max(
      0,
      items.findIndex((i) => i.getAttribute('aria-checked') === 'true')
    );
    const focusItem = (i) => {
      idx = ((i % items.length) + items.length) % items.length;
      items[idx]?.focus();
    };
    if (items.length) focusItem(idx);

    function onKeyDown(e) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        focusItem(idx + 1);
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        focusItem(idx - 1);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        closeAnyMenu();
        anchorEl.focus();
      }
    }
    function onPointerDown(e) {
      if (!menu.contains(e.target) && e.target !== anchorEl) closeAnyMenu();
    }
    menu.addEventListener('keydown', onKeyDown);
    document.addEventListener('pointerdown', onPointerDown, true);

    activeMenu = {
      el: menu,
      cleanup() {
        menu.removeEventListener('keydown', onKeyDown);
        document.removeEventListener('pointerdown', onPointerDown, true);
      },
    };
  }

  function addMenuItem(menu, { label, checked = null, onSelect }) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'still-menu-item';
    btn.setAttribute('role', checked === null ? 'menuitem' : 'menuitemradio');
    if (checked !== null) btn.setAttribute('aria-checked', String(checked));
    btn.tabIndex = -1;
    const checkSlot = el('span', 'still-menu-check');
    if (checked) checkSlot.appendChild(icon(PATHS.check, 10));
    btn.append(checkSlot, el('span', null, label));
    btn.addEventListener('click', () => onSelect());
    menu.appendChild(btn);
    return btn;
  }

  function addMenuSeparator(menu) {
    menu.appendChild(el('div', 'still-menu-separator'));
  }

  function openOutputMenu(appId, anchorEl) {
    openPopupMenu(anchorEl, 'left', (menu) => {
      const current = state.prefs[appId].output;
      addMenuItem(menu, {
        label: 'System output',
        checked: current === null,
        onSelect: () => {
          state.setOutput(appId, null);
          closeAnyMenu();
        },
      });
      addMenuSeparator(menu);
      for (const device of state.availableDevices()) {
        addMenuItem(menu, {
          label: device.name,
          checked: current === device.id,
          onSelect: () => {
            state.setOutput(appId, device.id);
            closeAnyMenu();
          },
        });
      }
    });
  }

  function openEllipsisMenu() {
    openPopupMenu(ellipsisBtn, 'right', (menu) => {
      addMenuItem(menu, {
        label: 'Show inactive apps',
        checked: showAllApps,
        onSelect: () => {
          showAllApps = !showAllApps;
          closeAnyMenu();
          render();
        },
      });
      addMenuItem(menu, {
        label: 'Refresh',
        onSelect: () => closeAnyMenu(),
      });
      addMenuSeparator(menu);
      addMenuItem(menu, {
        label: 'Quit Still',
        onSelect: () => {
          closeAnyMenu();
          // Mirrors onQuit in MixerPanel.swift: quitting Still hands every
          // app's volume and output back to macOS rather than leaving them
          // muted or rerouted.
          state.setEnabled(false);
          close();
        },
      });
    });
  }

  // ---------------- toast ----------------

  function showToast(message) {
    toastEl.textContent = message;
    toastEl.classList.add('is-visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('is-visible'), 1800);
  }

  // ---------------- level meters ----------------

  function tick() {
    if (!openFlag) return;
    for (const id of meterTargets) {
      const refs = rowElements.get(id);
      if (!refs) continue;
      const peak = engine.outputPeak(id);
      const level = meterLevel(peak, meterPrev[id] || 0);
      meterPrev[id] = level;
      refs.meterFill.style.transform = `scaleX(${level})`;
    }
    rafId = requestAnimationFrame(tick);
  }
  function startMeterLoop() {
    if (rafId == null) rafId = requestAnimationFrame(tick);
  }
  function stopMeterLoop() {
    if (rafId != null) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
  }

  // ---------------- open / close ----------------

  function onDocKeyDown(e) {
    if (e.key === 'Escape') {
      e.preventDefault();
      close();
    }
  }

  function open() {
    if (openFlag) return;
    openFlag = true;
    lastSignature = null;
    unsubscribe = state.subscribe(render); // calls render() once, synchronously
    document.addEventListener('keydown', onDocKeyDown, true);
    startMeterLoop();
    const focusable = element.querySelector('button, input, [tabindex]');
    // Keyboard users land inside the panel; a mouse click doesn't paint a focus ring, like macOS.
    focusable?.focus({ focusVisible: false });
  }

  function close() {
    if (!openFlag) return;
    openFlag = false;
    closeAnyMenu();
    clearTimeout(toastTimer);
    toastEl.classList.remove('is-visible');
    if (unsubscribe) {
      unsubscribe();
      unsubscribe = null;
    }
    document.removeEventListener('keydown', onDocKeyDown, true);
    stopMeterLoop();
    onClose?.();
  }

  function isOpen() {
    return openFlag;
  }

  return { element, open, close, isOpen };
}
