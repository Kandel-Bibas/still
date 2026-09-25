// Behaviour for the landing-page sections: the still:// terminal, the mini mixer
// that mirrors state live, the install copy button, draggable stickers, and a
// pop-in reveal for cards/stickers on first scroll into view.

import { APPS } from './state.js';
import { meterLevel } from './audio.js';

const reduceMotion = () =>
  window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

export function mountSections({ state, engine }) {
  mountTerminal(state);
  mountMiniMixer(state, engine);
  mountCopyButton();
  mountDraggableStickers();
  mountPopIn();
}

/* ---------------- still:// terminal ---------------- */

function mountTerminal(state) {
  const term = document.getElementById('term');
  if (!term) return;

  term.querySelectorAll('[data-run-url]').forEach(button => {
    const line = button.closest('[data-term]');
    const output = line ? line.querySelector('[data-output]') : null;
    const url = button.getAttribute('data-run-url');
    button.setAttribute('aria-label', `Run ${url}`);
    button.addEventListener('click', () => {
      runCommand(state, url, output);
    });
  });

  const input = document.getElementById('term-custom-input');
  const customOutput = document.getElementById('term-custom-output');
  if (input) {
    input.addEventListener('keydown', event => {
      if (event.key !== 'Enter') return;
      const raw = input.value.trim();
      if (!raw) return;
      runCommand(state, extractUrl(raw), customOutput);
    });
  }
}

function extractUrl(text) {
  const match = text.match(/still:\/\/\S+/);
  return match ? match[0].replace(/["'\)\s]+$/, '') : text;
}

function runCommand(state, url, output) {
  const result = state.run(url);
  if (!output) return;
  output.textContent = result.message;
  output.classList.toggle('ok', result.ok);
  output.classList.toggle('err', !result.ok);
}

/* ---------------- mini mixer ---------------- */

function mountMiniMixer(state, engine) {
  const root = document.getElementById('mixer-faders');
  if (!root) return;

  const rows = new Map();
  root.querySelectorAll('[data-app]').forEach(el => {
    const id = el.getAttribute('data-app');
    rows.set(id, {
      el,
      fill: el.querySelector('[data-fill]'),
      meter: el.querySelector('[data-meter]'),
      pct: el.querySelector('[data-pct]'),
      level: 0,
    });
  });

  const render = () => {
    const parts = [];
    for (const app of APPS) {
      const row = rows.get(app.id);
      if (!row) continue;
      const pref = state.prefs[app.id];
      const percent = Math.round((pref.muted ? 0 : pref.volume) * 100);
      row.fill.style.height = `${percent}%`;
      row.pct.textContent = `${percent}%`;
      parts.push(`${app.name} ${percent}%${pref.muted ? ' muted' : ''}`);
    }
    root.setAttribute('aria-label', `Live mixer levels: ${parts.join(', ')}`);
  };

  state.subscribe(render);

  // Meters only animate while the mixer is visible and audio is running, and
  // never when the visitor prefers reduced motion.
  let rafId = null;
  let visible = false;

  const tick = () => {
    if (!visible || reduceMotion()) { rafId = null; return; }
    for (const app of APPS) {
      const row = rows.get(app.id);
      if (!row) continue;
      const peak = engine.started ? engine.outputPeak(app.id) : 0;
      row.level = meterLevel(peak, row.level);
      row.meter.style.height = `${Math.round(row.level * 100)}%`;
    }
    rafId = requestAnimationFrame(tick);
  };

  const start = () => {
    if (rafId !== null || reduceMotion()) return;
    rafId = requestAnimationFrame(tick);
  };
  const stop = () => {
    if (rafId !== null) cancelAnimationFrame(rafId);
    rafId = null;
    for (const row of rows.values()) { row.level = 0; row.meter.style.height = '0%'; }
  };

  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        visible = entry.isIntersecting;
        if (visible) start(); else stop();
      }
    }, { threshold: 0.1 });
    observer.observe(root);
  } else {
    visible = true;
    start();
  }
}

/* ---------------- install copy button ---------------- */

function mountCopyButton() {
  const button = document.getElementById('copy-install');
  if (!button) return;
  const card = button.closest('.code-card');
  const lines = card ? Array.from(card.querySelectorAll('li')).map(li => li.textContent.trim()) : [];
  const text = lines.join('\n');
  const original = button.textContent;

  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
    } catch {
      button.textContent = 'Select & copy';
    }
    setTimeout(() => { button.textContent = original; }, 1800);
  });
}

/* ---------------- draggable stickers ---------------- */

function mountDraggableStickers() {
  if (reduceMotion()) return;
  document.querySelectorAll('[data-sticker]').forEach(el => initDraggable(el));
}

function initDraggable(el) {
  let baseX = 0, baseY = 0, baseRot = 0;
  let dragging = false;
  let startX = 0, startY = 0, pointerId = null;

  el.style.transition = 'transform 0.35s cubic-bezier(0.34, 1.56, 0.64, 1)';

  const apply = (x, y, rot) => {
    el.style.transform = `translate(${x}px, ${y}px) rotate(${rot}deg)`;
  };

  el.addEventListener('pointerdown', event => {
    dragging = true;
    pointerId = event.pointerId;
    el.setPointerCapture(pointerId);
    startX = event.clientX;
    startY = event.clientY;
    el.style.transition = 'none';
  });

  el.addEventListener('pointermove', event => {
    if (!dragging || event.pointerId !== pointerId) return;
    const dx = event.clientX - startX;
    const dy = event.clientY - startY;
    const rot = Math.max(-18, Math.min(18, dx * 0.35));
    apply(baseX + dx, baseY + dy, baseRot + rot);
  });

  const release = event => {
    if (!dragging || event.pointerId !== pointerId) return;
    dragging = false;
    const dx = event.clientX - startX;
    const dy = event.clientY - startY;
    baseX += dx;
    baseY += dy;
    el.style.transition = 'transform 0.35s cubic-bezier(0.34, 1.56, 0.64, 1)';
    // Spring back slightly toward the drop point, settling the rotation.
    apply(baseX, baseY, baseRot * 0.3);
    baseRot *= 0.3;
  };

  el.addEventListener('pointerup', release);
  el.addEventListener('pointercancel', release);
}

/* ---------------- pop-in reveal ---------------- */

function mountPopIn() {
  const targets = document.querySelectorAll('.pop-in');
  if (!targets.length) return;
  if (reduceMotion() || !('IntersectionObserver' in window)) {
    targets.forEach(el => el.classList.add('is-visible'));
    return;
  }
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    }
  }, { threshold: 0.15 });
  targets.forEach(el => observer.observe(el));
}
