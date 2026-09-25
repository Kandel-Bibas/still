// Four fake apps that really make sound, and the routing Still applies to them.
// Every sound is synthesised here — no samples are downloaded.
//
//   generator ─▶ app bus ─▶ Still gain (5 ms ramp) ─▶ device colour ─▶ system volume ─▶ limiter ─▶ speakers
//                  │ pre-meter                │ post-meter
//
// Output devices are simulated: a web page can't pick your real outputs per app, so each
// device gets a recognisable colour — the laptop speakers lose their bass, headphones don't.

import { APPS, DEVICES } from './state.js';

const RAMP = 0.005; // seconds — the same ramp as Still's render callback
const LOOKAHEAD = 0.15;

export class AudioEngine {
  constructor(state) {
    this.state = state;
    this.ctx = null;
    this.handlers = { ping: new Set(), speaker: new Set(), power: new Set(), beat: new Set() };
    this.systemVolume = 0.8;
    this.routes = {};
    state.subscribe(() => this.apply());
  }

  get started() { return this.ctx !== null && this.ctx.state === 'running'; }

  on(event, handler) { this.handlers[event].add(handler); return () => this.handlers[event].delete(handler); }
  emit(event, value) { for (const h of this.handlers[event]) h(value); }

  /** Must be called from a user gesture. The first call starts every app, like a busy Mac. */
  async start() {
    const first = !this.ctx;
    if (first) this.build();
    await this.ctx.resume();
    if (first) for (const app of APPS) this.setPlaying(app.id, true);
    this.emit('power', true);
  }

  /** Silences the whole demo without changing any app's state. */
  async suspend() {
    if (!this.ctx) return;
    await this.ctx.suspend();
    this.emit('power', false);
  }

  build() {
    const ctx = new AudioContext({ latencyHint: 'interactive' });
    this.ctx = ctx;
    this.noise = makeNoise(ctx, 3);
    this.pink = makePinkNoise(ctx, 4);

    const limiter = ctx.createDynamicsCompressor();
    limiter.threshold.value = -10; limiter.knee.value = 6; limiter.ratio.value = 12;
    limiter.attack.value = 0.003; limiter.release.value = 0.2;
    this.master = ctx.createGain();
    this.master.gain.value = this.systemVolume;
    this.masterMeter = ctx.createAnalyser(); this.masterMeter.fftSize = 1024;
    this.master.connect(limiter).connect(this.masterMeter).connect(ctx.destination);

    this.devices = {};
    for (const device of DEVICES) this.devices[device.id] = buildDevice(ctx, device.kind, this.master);

    this.apps = {};
    for (const app of APPS) {
      const bus = ctx.createGain(); bus.gain.value = 0;
      const pre = ctx.createAnalyser(); pre.fftSize = 512;
      const still = ctx.createGain(); still.gain.value = 0;
      const post = ctx.createAnalyser(); post.fftSize = 512;
      bus.connect(pre); bus.connect(still); still.connect(post);
      this.apps[app.id] = { bus, pre, still, post, device: null, playing: false, generator: null };
    }
    this.apps.music.generator = new LofiLoop(ctx, this.apps.music.bus, this.noise, beat => this.emit('beat', beat));
    this.apps.browser.generator = new Rain(ctx, this.apps.browser.bus, this.pink, this.noise);
    this.apps.calls.generator = new Voices(ctx, this.apps.calls.bus, this.noise, i => this.emit('speaker', i));
    this.apps.pings.generator = new Pings(ctx, this.apps.pings.bus, message => this.emit('ping', message));

    this.timer = setInterval(() => this.tick(), 25);
    this.apply();
  }

  tick() {
    const until = this.ctx.currentTime + LOOKAHEAD;
    for (const id in this.apps) {
      const app = this.apps[id];
      if (app.playing) app.generator.schedule(until);
    }
  }

  /** Starts or stops an app's own playback — the app's play button, not Still. */
  setPlaying(id, playing) {
    this.state.setPlaying(id, playing);
    if (!this.ctx) return;
    const app = this.apps[id];
    if (app.playing === playing) return;
    app.playing = playing;
    const t = this.ctx.currentTime;
    app.bus.gain.cancelScheduledValues(t);
    app.bus.gain.setValueAtTime(app.bus.gain.value, t);
    app.bus.gain.linearRampToValueAtTime(playing ? 1 : 0, t + (playing ? 0.02 : 0.25));
    if (playing) app.generator.resume(t + 0.02);
    else app.generator.pause(t + 0.25);
  }

  setSystemVolume(value) {
    this.systemVolume = value;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(t);
    this.master.gain.setValueAtTime(this.master.gain.value, t);
    this.master.gain.linearRampToValueAtTime(value, t + 0.03);
  }

  /** Reads the state and moves every app's audio to where Still would send it. */
  apply() {
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    for (const device of DEVICES) {
      const on = this.state.connected[device.id] ? 1 : 0;
      this.devices[device.id].gate.gain.setTargetAtTime(on, t, 0.01);
    }
    for (const id in this.apps) {
      const app = this.apps[id];
      const { gain, device } = this.state.audible(id);
      if (device === app.device) {
        // While a move is pending the old route is still connected; the move sets the gain.
        if (!app.switching) ramp(app.still.gain, gain, t);
        continue;
      }
      // Changing device: silence the route, move it once the ramp has finished, then
      // bring the gain back. Rapid changes collapse into a single move to the latest device.
      ramp(app.still.gain, 0, t);
      app.device = device;
      clearTimeout(app.switching);
      app.switching = setTimeout(() => {
        app.switching = null;
        if (app.connectedTo) { app.still.disconnect(app.connectedTo); app.connectedTo = null; }
        if (!app.device) return;
        app.connectedTo = this.devices[app.device].input;
        app.still.connect(app.connectedTo);
        ramp(app.still.gain, this.state.audible(id).gain, this.ctx.currentTime);
      }, (RAMP + 0.002) * 1000);
    }
  }

  /** Peak of what the app itself is producing, before Still (0…1). */
  sourcePeak(id) { return this.ctx ? peak(this.apps[id].pre) : 0; }
  /** Peak after Still's gain — what the panel's meter shows (0…1). */
  outputPeak(id) {
    if (!this.ctx) return 0;
    const app = this.apps[id];
    return app.device ? peak(app.post) : 0;
  }
  devicePeak(id) { return this.ctx ? peak(this.devices[id].meter) : 0; }
  /** Loudness of everything leaving the Mac, for visuals (0…1). */
  masterLevel() { return this.ctx ? rms(this.masterMeter) : 0; }
}

/** LevelMeter.display from Sources/MixerCore/LevelMeter.swift. */
export function meterLevel(peakValue, previous, floorDB = -60, decay = 0.8) {
  let mapped = 0;
  if (Number.isFinite(peakValue) && peakValue > 0) {
    const db = 20 * Math.log10(peakValue);
    mapped = Math.min(Math.max((db - floorDB) / -floorDB, 0), 1);
  }
  const result = Math.max(mapped, previous * decay);
  return result < 0.001 ? 0 : result;
}

function ramp(param, value, t) {
  param.cancelScheduledValues(t);
  param.setValueAtTime(param.value, t);
  param.linearRampToValueAtTime(value, t + RAMP);
}

const scratch = new Float32Array(1024);
function peak(analyser) {
  const data = scratch.subarray(0, analyser.fftSize);
  analyser.getFloatTimeDomainData(data);
  let p = 0;
  for (let i = 0; i < data.length; i++) { const v = Math.abs(data[i]); if (v > p) p = v; }
  return Math.min(1, p);
}
function rms(analyser) {
  const data = scratch.subarray(0, analyser.fftSize);
  analyser.getFloatTimeDomainData(data);
  let s = 0;
  for (let i = 0; i < data.length; i++) s += data[i] * data[i];
  return Math.min(1, Math.sqrt(s / data.length) * 3);
}

function buildDevice(ctx, kind, destination) {
  const input = ctx.createGain();
  const gate = ctx.createGain();
  const meter = ctx.createAnalyser(); meter.fftSize = 512;
  let chain = input;
  const add = node => { chain.connect(node); chain = node; return node; };
  if (kind === 'speaker') {
    // Small laptop drivers: no deep bass, a forward midrange, soft top.
    const hp = add(ctx.createBiquadFilter()); hp.type = 'highpass'; hp.frequency.value = 240; hp.Q.value = 0.9;
    const mid = add(ctx.createBiquadFilter()); mid.type = 'peaking'; mid.frequency.value = 2400; mid.gain.value = 3; mid.Q.value = 0.8;
    const lp = add(ctx.createBiquadFilter()); lp.type = 'lowpass'; lp.frequency.value = 9000;
    const trim = add(ctx.createGain()); trim.gain.value = 1.1;
  } else if (kind === 'headphones') {
    const low = add(ctx.createBiquadFilter()); low.type = 'lowshelf'; low.frequency.value = 110; low.gain.value = 3;
  } else {
    const low = add(ctx.createBiquadFilter()); low.type = 'lowshelf'; low.frequency.value = 120; low.gain.value = 1.5;
    const lp = add(ctx.createBiquadFilter()); lp.type = 'lowpass'; lp.frequency.value = 15000;
  }
  add(gate); add(meter);
  chain.connect(destination);
  return { input, gate, meter };
}

function makeNoise(ctx, seconds) {
  const buffer = ctx.createBuffer(1, ctx.sampleRate * seconds, ctx.sampleRate);
  const data = buffer.getChannelData(0);
  for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
  return buffer;
}

function makePinkNoise(ctx, seconds) {
  const buffer = ctx.createBuffer(2, ctx.sampleRate * seconds, ctx.sampleRate);
  for (let c = 0; c < 2; c++) {
    const data = buffer.getChannelData(c);
    let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
    for (let i = 0; i < data.length; i++) {
      const w = Math.random() * 2 - 1;
      b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759;
      b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856;
      b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980;
      data[i] = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11;
      b6 = w * 0.115926;
    }
  }
  return buffer;
}

const midi = n => 440 * Math.pow(2, (n - 69) / 12);

/** A lo-fi loop at 84 bpm: Rhodes-ish chords, bass, swung drums, vinyl crackle. */
class LofiLoop {
  constructor(ctx, out, noise, onBeat) {
    this.ctx = ctx; this.noise = noise; this.onBeat = onBeat;
    this.out = ctx.createGain(); this.out.gain.value = 0.55;
    const warmth = ctx.createBiquadFilter(); warmth.type = 'lowpass'; warmth.frequency.value = 5200;
    this.out.connect(warmth).connect(out);
    this.step = 0; this.next = 0;
    this.sixteenth = 60 / 84 / 4;
    this.chords = [[53, 57, 60, 64], [52, 55, 59, 62], [50, 53, 57, 60], [48, 52, 55, 59]];
    this.bass = [41, 40, 38, 36];
    this.melody = [72, 69, 67, 64, 67, 69, 72, 74];
    // Vinyl crackle runs underneath the whole loop.
    const crackle = ctx.createBufferSource(); crackle.buffer = noise; crackle.loop = true;
    const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 2500;
    this.crackleGain = ctx.createGain(); this.crackleGain.gain.value = 0.012;
    crackle.connect(hp).connect(this.crackleGain).connect(this.out);
    crackle.start();
  }
  resume(t) { this.next = Math.max(this.next, t); }
  pause() {}
  schedule(until) {
    while (this.next < until) {
      const s = this.step % 16, bar = Math.floor(this.step / 16) % 4;
      const swing = s % 2 === 1 ? this.sixteenth * 0.18 : 0;
      const t = this.next + swing;
      if (s === 0) this.chord(this.chords[bar], t);
      if (s === 0 || s === 10) this.bassNote(this.bass[bar], t, s === 0 ? 0.9 : 0.5);
      if (s === 0 || s === 7 || s === 10) this.kick(t, s === 0 ? 1 : 0.7);
      if (s === 4 || s === 12) this.snare(t);
      if (s % 2 === 0) this.hat(t, s % 4 === 0 ? 0.09 : 0.05);
      if ((s === 3 || s === 6 || s === 11 || s === 14) && Math.random() < 0.55) {
        this.bell(this.melody[(this.step + bar * 3) % this.melody.length], t);
      }
      if (Math.random() < 0.05) this.pop(t);
      if (s % 4 === 0) {
        // Beats are announced when they're heard, not when they're scheduled.
        const beat = { index: s / 4, downbeat: s === 0 };
        setTimeout(() => this.onBeat(beat), Math.max(0, (t - this.ctx.currentTime) * 1000));
      }
      this.next += this.sixteenth; this.step++;
    }
  }
  chord(notes, t) {
    const dur = this.sixteenth * 15;
    for (const n of notes) {
      for (const [type, detune, level] of [['sine', 0, 0.06], ['triangle', 6, 0.025]]) {
        const o = this.ctx.createOscillator(); o.type = type; o.frequency.value = midi(n); o.detune.value = detune;
        const g = this.ctx.createGain();
        g.gain.setValueAtTime(0, t);
        g.gain.linearRampToValueAtTime(level, t + 0.02);
        g.gain.exponentialRampToValueAtTime(level * 0.35, t + 0.9);
        g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
        o.connect(g).connect(this.out); o.start(t); o.stop(t + dur + 0.05);
      }
    }
  }
  bassNote(n, t, v) {
    const o = this.ctx.createOscillator(); o.type = 'triangle'; o.frequency.value = midi(n);
    const g = this.ctx.createGain();
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.28 * v, t + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t + this.sixteenth * 5);
    o.connect(g).connect(this.out); o.start(t); o.stop(t + this.sixteenth * 5 + 0.05);
  }
  kick(t, v) {
    const o = this.ctx.createOscillator(); o.type = 'sine';
    o.frequency.setValueAtTime(120, t); o.frequency.exponentialRampToValueAtTime(42, t + 0.12);
    const g = this.ctx.createGain();
    g.gain.setValueAtTime(0.75 * v, t); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.38);
    o.connect(g).connect(this.out); o.start(t); o.stop(t + 0.4);
  }
  snare(t) {
    const n = this.ctx.createBufferSource(); n.buffer = this.noise;
    const bp = this.ctx.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = 1900; bp.Q.value = 0.7;
    const g = this.ctx.createGain();
    g.gain.setValueAtTime(0.28, t); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.2);
    n.connect(bp).connect(g).connect(this.out); n.start(t, Math.random()); n.stop(t + 0.22);
    const body = this.ctx.createOscillator(); body.type = 'triangle'; body.frequency.value = 185;
    const bg = this.ctx.createGain(); bg.gain.setValueAtTime(0.12, t); bg.gain.exponentialRampToValueAtTime(0.0001, t + 0.08);
    body.connect(bg).connect(this.out); body.start(t); body.stop(t + 0.1);
  }
  hat(t, level) {
    const n = this.ctx.createBufferSource(); n.buffer = this.noise;
    const hp = this.ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 7500;
    const g = this.ctx.createGain();
    g.gain.setValueAtTime(level * (0.7 + Math.random() * 0.5), t); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.045);
    n.connect(hp).connect(g).connect(this.out); n.start(t, Math.random() * 2); n.stop(t + 0.06);
  }
  bell(n, t) {
    const o = this.ctx.createOscillator(); o.type = 'sine'; o.frequency.value = midi(n);
    const g = this.ctx.createGain();
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.05, t + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 1.1);
    o.connect(g).connect(this.out); o.start(t); o.stop(t + 1.2);
  }
  pop(t) {
    const n = this.ctx.createBufferSource(); n.buffer = this.noise;
    const g = this.ctx.createGain(); g.gain.setValueAtTime(0.05, t); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.01);
    n.connect(g).connect(this.out); n.start(t, Math.random() * 2); n.stop(t + 0.02);
  }
}

/** Steady rain in a browser tab: filtered pink noise plus droplets panned across the field. */
class Rain {
  constructor(ctx, out, pink, noise) {
    this.ctx = ctx; this.noise = noise; this.next = 0;
    this.out = ctx.createGain(); this.out.gain.value = 0.9;
    this.out.connect(out);
    const bed = ctx.createBufferSource(); bed.buffer = pink; bed.loop = true;
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 3800;
    const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 260;
    const g = ctx.createGain(); g.gain.value = 0.55;
    bed.connect(hp).connect(lp).connect(g).connect(this.out);
    bed.start();
  }
  resume(t) { this.next = Math.max(this.next, t); }
  pause() {}
  schedule(until) {
    while (this.next < until) {
      const t = this.next;
      const n = this.ctx.createBufferSource(); n.buffer = this.noise;
      const bp = this.ctx.createBiquadFilter(); bp.type = 'bandpass';
      bp.frequency.value = 1800 + Math.random() * 4200; bp.Q.value = 6;
      const pan = this.ctx.createStereoPanner(); pan.pan.value = Math.random() * 2 - 1;
      const g = this.ctx.createGain();
      g.gain.setValueAtTime(0.05 + Math.random() * 0.12, t); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.025);
      n.connect(bp).connect(g).connect(pan).connect(this.out);
      n.start(t, Math.random() * 2); n.stop(t + 0.04);
      this.next += 0.03 + Math.random() * 0.11;
    }
  }
}

/** A meeting: three people talking in turn, synthesised from a buzz and moving vowel formants. */
const VOWELS = [[730, 1090, 2440], [530, 1840, 2480], [270, 2290, 3010], [570, 840, 2410], [300, 870, 2240], [660, 1720, 2410]];
class Voices {
  constructor(ctx, out, noise, onSpeaker) {
    this.ctx = ctx; this.noise = noise; this.onSpeaker = onSpeaker;
    this.out = ctx.createGain(); this.out.gain.value = 1.4;
    // Call audio is band-limited, like a real conference line.
    const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 220;
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 3600;
    this.out.connect(hp).connect(lp).connect(out);
    this.people = [
      { pitch: 118, shift: 1.0, pan: -0.35 },
      { pitch: 205, shift: 1.17, pan: 0.3 },
      { pitch: 160, shift: 1.08, pan: 0.05 },
    ].map(p => this.person(p));
    this.next = 0; this.speaker = -1; this.phraseEnd = 0; this.timers = [];
  }
  person({ pitch, shift, pan }) {
    const ctx = this.ctx;
    const osc = ctx.createOscillator(); osc.type = 'sawtooth'; osc.frequency.value = pitch;
    const vibrato = ctx.createOscillator(); vibrato.frequency.value = 5.2;
    const depth = ctx.createGain(); depth.gain.value = pitch * 0.012;
    vibrato.connect(depth).connect(osc.frequency);
    const env = ctx.createGain(); env.gain.value = 0;
    const panner = ctx.createStereoPanner(); panner.pan.value = pan;
    const formants = [1, 0.45, 0.2].map(level => {
      const f = ctx.createBiquadFilter(); f.type = 'bandpass'; f.Q.value = 9;
      const g = ctx.createGain(); g.gain.value = level * 2.2;
      osc.connect(f).connect(g).connect(env);
      return f;
    });
    env.connect(panner).connect(this.out);
    osc.start(); vibrato.start();
    return { osc, env, formants, pitch, shift };
  }
  resume(t) { this.next = Math.max(this.next, t + 0.3); }
  pause() { this.announce(-1, this.ctx.currentTime); }
  announce(index, t) {
    const delay = Math.max(0, (t - this.ctx.currentTime) * 1000);
    setTimeout(() => this.onSpeaker(index), delay);
  }
  schedule(until) {
    while (this.next < until) {
      if (this.next >= this.phraseEnd) {
        // Pause, then someone else picks up the conversation.
        const gap = 0.25 + Math.random() * 0.9;
        const choices = [0, 1, 2].filter(i => i !== this.speaker);
        this.speaker = choices[Math.floor(Math.random() * choices.length)];
        this.announce(-1, this.next);
        this.next += gap;
        this.phraseEnd = this.next + 1.6 + Math.random() * 3.2;
        this.announce(this.speaker, this.next);
        continue;
      }
      this.syllable(this.people[this.speaker], this.next);
      this.next += 0.11 + Math.random() * 0.17;
    }
  }
  syllable(p, t) {
    const vowel = VOWELS[Math.floor(Math.random() * VOWELS.length)];
    const dur = 0.09 + Math.random() * 0.14;
    const inflection = 0.85 + Math.random() * 0.35;
    p.osc.frequency.setTargetAtTime(p.pitch * inflection, t, 0.04);
    p.formants.forEach((f, i) => f.frequency.setTargetAtTime(vowel[i] * p.shift, t, 0.02));
    p.env.gain.setTargetAtTime(0.5 + Math.random() * 0.4, t, 0.015);
    p.env.gain.setTargetAtTime(0.0001, t + dur, 0.03);
    if (Math.random() < 0.4) {
      // A consonant: a short breath of hiss before the vowel.
      const n = this.ctx.createBufferSource(); n.buffer = this.noise;
      const bp = this.ctx.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = 3000 + Math.random() * 2500; bp.Q.value = 1.5;
      const g = this.ctx.createGain();
      g.gain.setValueAtTime(0.08, t - 0.03); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.02);
      n.connect(bp).connect(g).connect(this.out); n.start(t - 0.03, Math.random() * 2); n.stop(t + 0.03);
    }
  }
}

/** A chat app that won't stop pinging. */
const MESSAGES = [
  { from: 'Priya', text: 'did anyone see the deploy logs?' },
  { from: 'Marcus', text: 'lunch at 12:30?' },
  { from: 'design-team', text: 'New comments on "Onboarding v4"' },
  { from: 'Sam', text: 'can you review my PR when you get a sec' },
  { from: 'general', text: 'Reminder: all-hands moved to Thursday' },
  { from: 'Aiko', text: '🎉 shipped!' },
  { from: 'Leo', text: 'ping' },
  { from: 'Leo', text: 'ping ping' },
];
class Pings {
  constructor(ctx, out, onPing) {
    this.ctx = ctx; this.onPing = onPing;
    this.out = ctx.createGain(); this.out.gain.value = 0.9;
    this.out.connect(out);
    this.next = 0; this.index = 0;
  }
  resume(t) { this.next = Math.max(this.next, t + 1.8); }
  pause() {}
  schedule(until) {
    while (this.next < until) {
      const t = this.next;
      [[1318.5, 0], [1975.5, 0.09]].forEach(([f, offset]) => {
        const o = this.ctx.createOscillator(); o.type = 'sine'; o.frequency.value = f;
        const g = this.ctx.createGain();
        g.gain.setValueAtTime(0, t + offset); g.gain.linearRampToValueAtTime(0.22, t + offset + 0.005);
        g.gain.exponentialRampToValueAtTime(0.0001, t + offset + 0.7);
        o.connect(g).connect(this.out); o.start(t + offset); o.stop(t + offset + 0.75);
      });
      const message = MESSAGES[this.index++ % MESSAGES.length];
      setTimeout(() => this.onPing(message), Math.max(0, (t - this.ctx.currentTime) * 1000));
      this.next += 4.5 + Math.random() * 4;
    }
  }
}
