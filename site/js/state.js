// The demo's model of Still. Routing mirrors Sources/MixerCore/RoutingPolicy.swift and
// RouteReconciler.swift so the panel on this page behaves like the real app: an untouched
// app keeps its original audio, a chosen device that disappears leaves the app muted and
// waiting, and switching Still off hands every app back.

export const DEVICES = [
  { id: 'speakers', name: 'MacBook Pro Speakers', kind: 'speaker', removable: false },
  { id: 'headphones', name: 'Studio Headphones', kind: 'headphones', removable: true },
  { id: 'airpods', name: 'AirPods Pro', kind: 'airpods', removable: true },
];

export const APPS = [
  { id: 'music', name: 'Music', bundle: 'com.demo.music', blurb: 'Lo-fi loop' },
  { id: 'browser', name: 'Browser', bundle: 'com.demo.browser', blurb: 'Rain sounds in a tab' },
  { id: 'calls', name: 'Calls', bundle: 'com.demo.calls', blurb: 'Weekly sync' },
  { id: 'pings', name: 'Pings', bundle: 'com.demo.pings', blurb: 'Team chat' },
];

/** @typedef {{ volume: number, muted: boolean, pinned: boolean, output: string | null }} Preference */
/** @typedef {{ kind: 'direct' } | { kind: 'waiting' } | { kind: 'render', device: string }} Decision */

export class StillState {
  constructor() {
    this.enabled = true;
    this.defaultDevice = 'speakers';
    /** @type {Record<string, boolean>} */
    this.connected = { speakers: true, headphones: true, airpods: true };
    /** @type {Record<string, Preference>} */
    this.prefs = {
      music: { volume: 0.42, muted: false, pinned: true, output: 'headphones' },
      browser: { volume: 0.75, muted: false, pinned: false, output: null },
      calls: { volume: 1, muted: false, pinned: false, output: null },
      pings: { volume: 1, muted: false, pinned: false, output: null },
    };
    /** @type {Record<string, boolean>} whether each app is currently producing sound */
    this.playing = { music: false, browser: false, calls: false, pings: false };
    this.listeners = new Set();
  }

  subscribe(listener) {
    this.listeners.add(listener);
    listener(this);
    return () => this.listeners.delete(listener);
  }

  emit() { for (const listener of this.listeners) listener(this); }

  device(id) { return DEVICES.find(d => d.id === id); }
  app(id) { return APPS.find(a => a.id === id); }
  availableDevices() { return DEVICES.filter(d => this.connected[d.id]); }

  /** Amplitude Still applies. The slider never boosts; mute keeps the saved volume. */
  gain(id) {
    const p = this.prefs[id];
    return p.muted ? 0 : clamp01(p.volume);
  }

  /** RoutingPolicy.decide */
  decide(id) {
    const p = this.prefs[id];
    if (!this.enabled) return { kind: 'direct' };
    if (p.output) return this.connected[p.output] ? { kind: 'render', device: p.output } : { kind: 'waiting' };
    if (this.gain(id) === 1) return { kind: 'direct' };
    return this.connected[this.defaultDevice] ? { kind: 'render', device: this.defaultDevice } : { kind: 'waiting' };
  }

  /** What the listener actually hears for an app: its gain and the device it plays on. */
  audible(id) {
    const d = this.decide(id);
    if (d.kind === 'direct') return { gain: 1, device: this.defaultDevice };
    if (d.kind === 'waiting') return { gain: 0, device: null };
    return { gain: this.gain(id), device: d.device };
  }

  /** The status line under a row, exactly as MixerAppRow.routeStatus shows it (empty = no line). */
  status(id) {
    const d = this.decide(id);
    const active = this.playing[id];
    if (d.kind === 'waiting') {
      const name = this.device(this.prefs[id].output ?? this.defaultDevice)?.name ?? 'an audio output';
      return { kind: 'waiting', label: `Muted · waiting for ${name}` };
    }
    if (!active) return { kind: 'inactive', label: 'Not playing' };
    return d.kind === 'direct' ? { kind: 'direct', label: '' } : { kind: 'managed', label: '' };
  }

  outputLabel(id) {
    const out = this.prefs[id].output;
    return out ? this.device(out).name : 'System output';
  }

  // Mutations — each one mirrors a MixerStore method.
  setVolume(id, value) { this.prefs[id].volume = clamp01(value); this.emit(); }
  toggleMute(id) { this.prefs[id].muted = !this.prefs[id].muted; this.emit(); }
  setMuted(id, muted) { this.prefs[id].muted = muted; this.emit(); }
  togglePin(id) { this.prefs[id].pinned = !this.prefs[id].pinned; this.emit(); }
  setOutput(id, deviceId) { this.prefs[id].output = deviceId; this.emit(); }
  setEnabled(enabled) { this.enabled = enabled; this.emit(); }
  setPlaying(id, playing) {
    if (this.playing[id] === playing) return;
    this.playing[id] = playing; this.emit();
  }

  setDefaultDevice(id) {
    if (!this.connected[id]) return;
    this.defaultDevice = id; this.emit();
  }

  /** Plugging a device in or out. Like macOS, losing the default output falls back to the speakers. */
  setConnected(id, connected) {
    const device = this.device(id);
    if (!device?.removable) return;
    this.connected[id] = connected;
    if (!connected && this.defaultDevice === id) this.defaultDevice = 'speakers';
    this.emit();
  }

  /** Runs a still:// URL exactly as AutomationHandler does. Returns a message for the terminal. */
  run(url) {
    let command;
    try { command = parseCommand(url); } catch (error) { return { ok: false, message: error.message }; }
    if (!this.enabled) return { ok: false, message: 'Turn Still on to control apps from Shortcuts.' };
    try {
      const id = match(command.app, APPS.map(a => ({ id: a.bundle, name: a.name, key: a.id })), 'app');
      if (command.kind === 'volume') {
        this.setVolume(id, command.percent / 100);
        return { ok: true, message: `${this.app(id).name} volume set to ${fmt(command.percent)}%.` };
      }
      if (command.kind === 'mute') {
        const muted = command.state === 'toggle' ? !this.prefs[id].muted : command.state === 'on';
        this.setMuted(id, muted);
        return { ok: true, message: `${this.app(id).name} ${muted ? 'muted' : 'unmuted'}.` };
      }
      if (command.device === null) {
        this.setOutput(id, null);
        return { ok: true, message: `${this.app(id).name} now follows the system output.` };
      }
      const device = match(command.device, DEVICES.map(d => ({ id: d.id, name: d.name, key: d.id })), 'device');
      this.setOutput(id, device);
      const waiting = this.connected[device] ? '' : ' It stays muted until that device is back.';
      return { ok: true, message: `${this.app(id).name} → ${this.device(device).name}.${waiting}` };
    } catch (error) {
      return { ok: false, message: error.message };
    }
  }
}

/** AutomationCommand.parse */
export function parseCommand(url) {
  let parsed;
  try { parsed = new URL(url); } catch { throw new Error('Still only understands still:// URLs.'); }
  if (parsed.protocol !== 'still:') throw new Error(`Still only understands still:// URLs, not ${parsed.protocol}//.`);
  const command = (parsed.host || parsed.pathname.replace(/^\/+/, '')).toLowerCase();
  const value = name => { const v = parsed.searchParams.get(name); return v ? v : null; };
  if (!['volume', 'mute', 'output'].includes(command)) {
    throw new Error(command ? `Unknown command '${command}'. Use volume, mute, or output.` : 'Missing command. Use still://volume, still://mute, or still://output.');
  }
  const app = value('app');
  if (!app) throw new Error("Missing 'app' in the still:// URL.");
  if (command === 'volume') {
    const raw = value('value');
    if (!raw) throw new Error("Missing 'value' in the still:// URL.");
    const percent = Number(raw);
    if (raw.trim() === '' || !Number.isFinite(percent)) throw new Error(`'${raw}' is not a number.`);
    if (percent < 0 || percent > 100) throw new Error(`Volume must be between 0 and 100, got ${raw}.`);
    return { kind: 'volume', app, percent };
  }
  if (command === 'mute') {
    const raw = value('state') ?? 'toggle';
    const state = raw.toLowerCase();
    if (!['on', 'off', 'toggle'].includes(state)) throw new Error(`Unknown mute state '${raw}'. Use on, off, or toggle.`);
    return { kind: 'mute', app, state };
  }
  const device = value('device');
  if (!device) throw new Error("Missing 'device' in the still:// URL.");
  return { kind: 'output', app, device: device.toLowerCase() === 'system' ? null : device };
}

/** AutomationCommand.match: exact id first, then a unique case-insensitive name. Returns the key. */
function match(query, candidates, target) {
  const exact = candidates.find(c => c.id === query);
  if (exact) return exact.key;
  const byName = candidates.filter(c => c.name.toLowerCase() === query.toLowerCase());
  const noun = target === 'app' ? 'app' : 'output device';
  if (byName.length === 0) throw new Error(`No ${noun} named "${query}".`);
  if (byName.length > 1) throw new Error(`"${query}" matches more than one ${noun}.`);
  return byName[0].key;
}

function clamp01(v) { return Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0; }
function fmt(n) { return Number.isInteger(n) ? String(n) : n.toFixed(1); }
