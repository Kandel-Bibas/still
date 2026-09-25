// Hero stickers dance to the demo's music: they hop on the beat, by as much as the Music
// app is actually audible through Still. Turn Music down and they calm down; mute it and
// they go back to floating.

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

export function mountDance(stickers, { state, engine }) {
  stickers.forEach((sticker, i) => {
    sticker.classList.add('floating');
    sticker.style.setProperty('--float-delay', `${(i * -1.37).toFixed(2)}s`);
    sticker.style.setProperty('--float-duration', `${(3.2 + (i % 3) * 0.7).toFixed(1)}s`);
  });

  engine.on('beat', ({ index, downbeat }) => {
    if (reduceMotion.matches || document.hidden) return;
    const { gain } = state.audible('music');
    const loudness = gain * engine.systemVolume;
    if (loudness < 0.02 || !state.playing.music) return;
    stickers.forEach((sticker, i) => {
      // Everyone hops on the downbeat; otherwise alternate stickers take turns.
      if (!downbeat && (index + i) % 2 === 1) return;
      const lift = (downbeat ? 16 : 10) * Math.min(1, loudness * 1.4);
      const squash = 1 + 0.12 * Math.min(1, loudness * 1.4);
      sticker.animate([
        { scale: '1 1', translate: '0 0' },
        { scale: `${2 - squash} ${squash}`, translate: `0 ${-lift}px`, offset: 0.35 },
        { scale: `${squash} ${2 - squash}`, translate: '0 0', offset: 0.7 },
        { scale: '1 1', translate: '0 0' },
      ], { duration: 360, easing: 'cubic-bezier(.3,.7,.4,1)', composite: 'replace' });
    });
  });
}
