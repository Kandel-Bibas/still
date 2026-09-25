// A note rides the "how it works" tube from the app to your output, and each stage hops
// as the sound passes through it.

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const TRAVEL = 5200; // ms from the first node to the last
const REST = 900;    // ms pause before the next note sets off

export function mountPipeline(pipeline) {
  if (!pipeline) return;
  const tubes = [...pipeline.querySelectorAll('.pipeline-tube')];
  const nodes = [...pipeline.querySelectorAll('.node-icon')];
  const bead = document.createElement('span');
  bead.className = 'pipeline-bead';
  bead.setAttribute('aria-hidden', 'true');
  bead.innerHTML = '<svg><use href="assets/stickers.svg#note"/></svg>';
  pipeline.append(bead);

  let frame = 0, start = 0, visible = false, hit = new Set();

  function activeTube() {
    const svg = tubes.find(t => getComputedStyle(t).display !== 'none');
    // The second path is the tube's body; the first is its darker underside.
    return svg && { svg, path: svg.querySelectorAll('path')[1] };
  }

  function tick(now) {
    frame = requestAnimationFrame(tick);
    const tube = activeTube();
    if (!tube) return;
    if (!start) start = now;
    const elapsed = (now - start) % (TRAVEL + REST);
    if (elapsed < 16) hit = new Set();
    const progress = Math.min(1, elapsed / TRAVEL);
    const eased = progress < 0.5 ? 2 * progress * progress : 1 - Math.pow(-2 * progress + 2, 2) / 2;

    // Map a point on the stretched SVG path into the pipeline's own coordinates.
    const length = tube.path.getTotalLength();
    const point = tube.path.getPointAtLength(eased * length).matrixTransform(tube.svg.getScreenCTM());
    const box = pipeline.getBoundingClientRect();
    const x = point.x - box.left, y = point.y - box.top;
    const wobble = Math.sin(now / 90) * 10;
    bead.style.transform = `translate(${x}px, ${y}px) translate(-50%, -50%) rotate(${wobble}deg)`;
    bead.style.opacity = progress >= 1 ? '0' : '1';

    nodes.forEach((node, i) => {
      if (hit.has(i)) return;
      const r = node.getBoundingClientRect();
      const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      if (Math.hypot(point.x - cx, point.y - cy) < r.width * 0.55) {
        hit.add(i);
        node.animate([
          { scale: '1', translate: '0 0' },
          { scale: '1.14', translate: '0 -10px', offset: 0.4 },
          { scale: '0.96', translate: '0 0', offset: 0.75 },
          { scale: '1', translate: '0 0' },
        ], { duration: 420, easing: 'cubic-bezier(.3,.7,.4,1)' });
      }
    });
  }

  function run() {
    cancelAnimationFrame(frame);
    const on = visible && !document.hidden && !reduceMotion.matches;
    bead.hidden = !on;
    if (on) { start = 0; frame = requestAnimationFrame(tick); }
  }

  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; run(); }).observe(pipeline);
  document.addEventListener('visibilitychange', run);
  reduceMotion.addEventListener('change', run);
}
