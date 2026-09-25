import { StillState } from './state.js';
import { AudioEngine } from './audio.js';
import { mountTube } from './tube.js';
import { mountDance } from './dance.js';
import { mountPipeline } from './pipeline.js';

const state = new StillState();
const engine = new AudioEngine(state);
window.stillDemo = { state, engine };

const wordmark = document.querySelector('.wordmark');
const hero = document.querySelector('.hero');
mountTube(document.getElementById('hero-tube'), engine, {
  // Thread the wave through the middle of the wordmark.
  centre: () => {
    const h = hero.getBoundingClientRect(), w = wordmark.getBoundingClientRect();
    return w.top - h.top + w.height * 0.52;
  },
  amplitude: 0.12, wavelength: 0.58, thickness: 0.1,
  // Over the S, the i and the last l; behind the rest. Each range runs gap-midpoint to
  // gap-midpoint, where the tube is over paper and both layers look the same.
  front: document.getElementById('hero-tube-front'),
  frontRanges: () => {
    const origin = hero.getBoundingClientRect().left;
    const boxes = [...wordmark.querySelectorAll('.letters i')].map(i => i.getBoundingClientRect());
    const edge = (a, b) => (a.right + b.left) / 2 - origin;
    return [[0, edge(boxes[0], boxes[1])], [edge(boxes[1], boxes[2]), edge(boxes[2], boxes[3])],
            [edge(boxes[3], boxes[4]), hero.getBoundingClientRect().width]];
  },
});
const footerMark = document.querySelector('.footer-mark');
const footer = document.querySelector('.footer');
mountTube(document.getElementById('footer-tube'), engine, {
  centre: () => {
    const h = footer.getBoundingClientRect(), w = footerMark.getBoundingClientRect();
    return w.top - h.top + w.height * 0.55;
  },
  amplitude: 0.1, wavelength: 0.9, thickness: 0.11, speed: -0.16,
});

mountDance([...document.querySelectorAll('.hero .sticker')], { state, engine });
mountPipeline(document.querySelector('.pipeline'));

const soundToggle = document.getElementById('sound-toggle');
soundToggle.addEventListener('click', () => {
  if (engine.started) engine.suspend(); else engine.start();
});
engine.on('power', on => {
  soundToggle.setAttribute('aria-pressed', String(on));
  soundToggle.setAttribute('aria-label', on ? 'Turn sound off' : 'Turn sound on');
});

// Each part of the page mounts on its own so one failure can't blank the rest.
async function mount(path, name, ...args) {
  try {
    const module = await import(path);
    module[name](...args);
  } catch (error) {
    console.error(`Still demo: couldn't mount ${path}`, error);
  }
}
mount('./desktop.js', 'mountDesktop', document.getElementById('mac-demo'), { state, engine });
mount('./sections.js', 'mountSections', { state, engine });
