// The inflated blue tube: a travelling sound wave drawn as a grainy 3D ribbon.
// It swells with whatever the demo Mac is playing, so the page itself reacts to sound.

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

/**
 * @param {HTMLCanvasElement} canvas  fills its positioned parent
 * @param {{ masterLevel(): number }} engine
 * @param {{ centre?: () => number, front?: HTMLCanvasElement, frontRanges?: () => number[][],
 *           amplitude?: number, wavelength?: number, thickness?: number, speed?: number, swell?: number }} options
 *   centre returns the wave's baseline in CSS px from the canvas top; the rest are fractions of the canvas size.
 *   front is a second canvas stacked above the text: the tube is also drawn there, but only inside
 *   frontRanges ([x0, x1] in CSS px), so it weaves in front of some letters and behind others.
 */
export function mountTube(canvas, engine, options = {}) {
  const opt = { amplitude: 0.13, wavelength: 0.62, thickness: 0.085, speed: 0.22, swell: 1.8, ...options };
  const ctx = canvas.getContext('2d');
  const layer = document.createElement('canvas');
  const lctx = layer.getContext('2d');
  const grain = makeGrain();
  const front = opt.front ? opt.front.getContext('2d') : null;
  let width = 0, height = 0, dpr = 1, level = 0, visible = true, frame = 0, last = 0, pattern = null;

  function resize() {
    const rect = canvas.getBoundingClientRect();
    dpr = Math.min(devicePixelRatio || 1, 1.5);
    width = rect.width; height = rect.height;
    for (const c of [canvas, layer, opt.front].filter(Boolean)) { c.width = Math.round(width * dpr); c.height = Math.round(height * dpr); }
    pattern = lctx.createPattern(grain, 'repeat');
    draw(performance.now());
  }

  function wave(c, t, offset) {
    const thickness = Math.min(width, height * 1.6) * opt.thickness;
    const amplitude = height * opt.amplitude * (1 + level * opt.swell);
    const lambda = Math.max(width * opt.wavelength, 320);
    const centre = opt.centre ? opt.centre() : height / 2;
    const phase = t * opt.speed * 0.001 * Math.PI * 2;
    c.beginPath();
    for (let x = -thickness * 2; x <= width + thickness * 2; x += 6) {
      const k = (x / lambda) * Math.PI * 2;
      const y = centre + amplitude * (0.78 * Math.sin(k - phase) + 0.22 * Math.sin(k * 2.2 + phase * 0.7 + 1.3));
      if (x === -thickness * 2) c.moveTo(x, y + offset); else c.lineTo(x, y + offset);
    }
    return thickness;
  }

  function stroke(c, t, style, widthFactor, offsetFactor, blur = 0) {
    c.save();
    c.strokeStyle = style;
    if (blur) c.filter = `blur(${blur}px)`;
    const thickness = Math.min(width, height * 1.6) * opt.thickness;
    wave(c, t, thickness * offsetFactor);
    c.lineWidth = thickness * widthFactor;
    c.lineCap = 'round'; c.lineJoin = 'round';
    c.stroke();
    c.restore();
  }

  function draw(now) {
    if (!width) return;
    const t = reduceMotion.matches ? 0 : now;
    const target = engine.masterLevel();
    level += (target - level) * (target > level ? 0.18 : 0.04);

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    lctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);
    lctx.clearRect(0, 0, width, height);

    // Soft contact shadow on the paper below the tube.
    stroke(ctx, t, 'rgba(22, 70, 170, 0.22)', 0.95, 0.42, 16);

    // The tube itself, lit from above: underside, body, sheen, specular line.
    stroke(lctx, t, '#1a66d6', 1, 0);
    stroke(lctx, t, '#2f86f0', 0.9, -0.04);
    stroke(lctx, t, '#4da2ff', 0.7, -0.09);
    stroke(lctx, t, 'rgba(150, 202, 255, 0.95)', 0.3, -0.2, 5);
    stroke(lctx, t, 'rgba(255, 255, 255, 0.75)', 0.07, -0.27, 1.5);

    // Grain, only where the tube is.
    lctx.save();
    lctx.globalCompositeOperation = 'source-atop';
    lctx.globalAlpha = 0.5;
    lctx.fillStyle = pattern;
    lctx.fillRect(0, 0, width, height);
    lctx.restore();

    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(layer, 0, 0);

    if (front) {
      front.setTransform(1, 0, 0, 1, 0, 0);
      front.clearRect(0, 0, opt.front.width, opt.front.height);
      for (const [x0, x1] of opt.frontRanges()) {
        front.save();
        front.beginPath();
        front.rect(x0 * dpr, 0, (x1 - x0) * dpr, opt.front.height);
        front.clip();
        front.drawImage(layer, 0, 0);
        front.restore();
      }
    }
  }

  function loop(now) {
    frame = requestAnimationFrame(loop);
    if (now - last < 32) return; // ~30 fps is plenty for a slow wave
    last = now;
    draw(now);
  }

  function run() {
    cancelAnimationFrame(frame);
    if (visible && !document.hidden && !reduceMotion.matches) frame = requestAnimationFrame(loop);
    else draw(performance.now());
  }

  new ResizeObserver(resize).observe(canvas);
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; run(); }).observe(canvas);
  document.addEventListener('visibilitychange', run);
  reduceMotion.addEventListener('change', run);
  resize();
  run();
}

function makeGrain() {
  const size = 160;
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d');
  const image = g.createImageData(size, size);
  for (let i = 0; i < image.data.length; i += 4) {
    const r = Math.random();
    if (r < 0.16) { image.data.set([8, 40, 120, 90 + Math.random() * 120], i); }
    else if (r < 0.26) { image.data.set([235, 245, 255, 60 + Math.random() * 110], i); }
  }
  g.putImageData(image, 0, 0);
  return c;
}
