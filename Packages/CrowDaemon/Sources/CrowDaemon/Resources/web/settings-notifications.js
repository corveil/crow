'use strict';
// Crow web UI — Settings → Notifications (CROW-1160).
// previewSound / SOUND_TONES stay in sync with notifications.js.
(function () {
  const T = window.CrowSettingsTabs = window.CrowSettingsTabs || {};
  const S = new Proxy({}, {
    get(_, k) { return window.CrowSettings[k]; },
    set(_, k, v) { window.CrowSettings[k] = v; return true; },
  });

  const EVENT_LABELS = {
    taskComplete: 'Task Complete', agentWaiting: 'Agent Waiting',
    reviewRequested: 'Review Requested', changesRequested: 'Changes Requested',
    checksFailing: 'CI Failing',
    autoWorkspaceCreated: 'Auto-Workspace Created', autoMergeEnabled: 'Auto-Merge Enabled',
    autoMergeBlocked: 'Auto-Merge Blocked',
    autoRebasePushed: 'Branch Rebased', autoRebaseConflicts: 'Rebase Conflicts',
    autoRebaseStuck: 'Rebase Stuck',
    configReloaded: 'Config Reloaded',
  };
  // One-line "what fires this" hint per event, so the automation entries aren't
  // guesswork (CrowCore NotificationEvent.description).
  const EVENT_HINTS = {
    taskComplete: 'Claude finished responding.',
    agentWaiting: 'Claude needs your input or permission.',
    reviewRequested: 'Someone requested your review on a PR.',
    changesRequested: 'A reviewer requested changes on your PR.',
    checksFailing: 'CI checks started failing on your PR.',
    autoWorkspaceCreated: 'Crow auto-created a workspace for a crow:auto / crow:explore labeled issue.',
    autoMergeEnabled: 'Crow enabled auto-merge on a crow:merge-labeled PR.',
    autoMergeBlocked: "Crow gave up auto-merging a crow:merge PR — e.g. the repo has GitHub's \"Allow auto-merge\" off.",
    autoRebasePushed: 'Crow rebased a PR branch onto its base and force-pushed.',
    autoRebaseConflicts: 'An auto-rebase hit conflicts that need attention.',
    autoRebaseStuck: "An auto-rebase can't proceed — a dirty worktree, or local commits a force-push would destroy.",
    configReloaded: 'Crow picked up a change to config.json.',
  };
  // Canonical NotificationEvent set + defaults (CrowCore NotificationEvent) —
  // the config only stores events the user has touched, so we render all of them
  // and materialize any missing ones with their default sound (CROW-593). The
  // trailing seven are Crow's own automation events (CROW-768, #888, #944).
  const EVENT_ORDER = [
    'taskComplete', 'agentWaiting', 'reviewRequested', 'changesRequested', 'checksFailing',
    'autoWorkspaceCreated', 'autoMergeEnabled', 'autoMergeBlocked', 'autoRebasePushed',
    'autoRebaseConflicts', 'autoRebaseStuck', 'configReloaded',
  ];
  const EVENT_DEFAULT_SOUND = {
    taskComplete: 'Glass', agentWaiting: 'Funk', reviewRequested: 'Glass',
    changesRequested: 'Funk', checksFailing: 'Sosumi',
    autoWorkspaceCreated: 'Hero', autoMergeEnabled: 'Glass', autoMergeBlocked: 'Basso',
    autoRebasePushed: 'Bottle', autoRebaseConflicts: 'Basso', autoRebaseStuck: 'Basso',
    configReloaded: 'Tink',
  };
  const BUILT_IN_SOUNDS = [
    'Basso', 'Blow', 'Bottle', 'Frog', 'Funk', 'Glass', 'Hero', 'Morse',
    'Ping', 'Pop', 'Purr', 'Sosumi', 'Submarine', 'Tink',
  ];
  // Built-ins plus custom library names, filled from `notifications-get` when
  // Settings opens. Falls back to BUILT_IN_SOUNDS if that RPC fails.
  let availableSounds = BUILT_IN_SOUNDS.slice();
  let customSounds = []; // [{name, file, url}]
  // The app plays macOS system sounds (NSSound) that don't exist in a browser,
  // so the web preview synthesizes a short distinct tone per name via Web Audio
  // — an approximation, no bundled assets (CROW-593). Each recipe is a list of
  // { freq, at?, dur?, type? } oscillator steps.
  const SOUND_TONES = {
    Basso:     [{ freq: 147, type: 'sawtooth', dur: 0.22 }],
    Blow:      [{ freq: 523, type: 'sine', dur: 0.18 }],
    Bottle:    [{ freq: 392, type: 'sine', dur: 0.12 }, { freq: 784, at: 0.08, dur: 0.1 }],
    Frog:      [{ freq: 196, type: 'square', dur: 0.1 }, { freq: 294, at: 0.1, type: 'square', dur: 0.12 }],
    Funk:      [{ freq: 220, type: 'triangle', dur: 0.14 }, { freq: 330, at: 0.12, type: 'triangle', dur: 0.14 }],
    Glass:     [{ freq: 880, type: 'sine', dur: 0.12 }, { freq: 1320, at: 0.06, dur: 0.16 }],
    Hero:      [{ freq: 523, type: 'sine', dur: 0.12 }, { freq: 784, at: 0.12, dur: 0.18 }],
    Morse:     [{ freq: 660, type: 'square', dur: 0.08 }, { freq: 660, at: 0.14, type: 'square', dur: 0.08 }],
    Ping:      [{ freq: 1046, type: 'sine', dur: 0.14 }],
    Pop:       [{ freq: 440, type: 'sine', dur: 0.07 }],
    Purr:      [{ freq: 165, type: 'triangle', dur: 0.22 }],
    Sosumi:    [{ freq: 660, type: 'square', dur: 0.1 }, { freq: 440, at: 0.1, type: 'square', dur: 0.16 }],
    Submarine: [{ freq: 131, type: 'sine', dur: 0.28 }],
    Tink:      [{ freq: 1318, type: 'sine', dur: 0.1 }],
    _default:  [{ freq: 700, type: 'sine', dur: 0.14 }],
  };
  let _audioCtx = null;
  function previewSound(name) {
    if (window.crowSound && typeof window.crowSound.play === 'function') {
      window.crowSound.play(name);
      return;
    }
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    try {
      _audioCtx = _audioCtx || new AC();
      const ctx = _audioCtx;
      if (ctx.state === 'suspended') ctx.resume(); // unlocked by the click gesture
      const recipe = SOUND_TONES[name] || SOUND_TONES._default;
      const now = ctx.currentTime;
      for (const step of recipe) {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = step.type || 'sine';
        osc.frequency.value = step.freq;
        const t0 = now + (step.at || 0);
        const dur = step.dur || 0.12;
        gain.gain.setValueAtTime(0.0001, t0);
        gain.gain.exponentialRampToValueAtTime(0.2, t0 + 0.012);
        gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(t0);
        osc.stop(t0 + dur + 0.03);
      }
    } catch (_) { /* Web Audio unavailable */ }
  }

  // ---- Notifications ------------------------------------------------------

  // Custom sound library (CROW-1147). Upload and remove apply immediately —
  // they write the Application Support sounds/ dir, not config.json — so they
  // do not mark the form dirty. Choosing a custom name in a picker still does.
  function customSoundLibrary() {
    const wrap = el('div', 'st-sound-lib');
    if (customSounds.length === 0) {
      wrap.appendChild(el('div', 'st-help', 'No custom sounds yet.'));
    } else {
      for (const sound of customSounds) {
        const row = el('div', 'st-sound-lib-row');
        row.appendChild(el('span', 'st-sound-lib-name', sound.name));
        const preview = el('button', 'action-btn', '▶ Preview');
        preview.type = 'button';
        preview.onclick = () => previewSound(sound.name);
        const del = el('button', 'action-btn', 'Remove');
        del.type = 'button';
        del.onclick = () => removeCustomSound(sound.name);
        row.appendChild(preview);
        row.appendChild(del);
        wrap.appendChild(row);
      }
    }
    const actions = el('div', 'st-sound-row');
    const input = el('input');
    input.type = 'file';
    input.accept = '.wav,.mp3,.aiff,.aif,audio/wav,audio/mpeg,audio/aiff';
    input.style.display = 'none';
    input.onchange = () => {
      const file = input.files && input.files[0];
      input.value = '';
      if (file) uploadCustomSound(file);
    };
    const btn = el('button', 'action-btn', 'Upload sound');
    btn.type = 'button';
    btn.onclick = () => input.click();
    actions.appendChild(btn);
    actions.appendChild(input);
    wrap.appendChild(actions);
    return S.field('Custom sounds', wrap,
      'WAV, MP3, or AIFF, up to 2 MB. Stored on this machine and playable in the web app. Dropping a file into ~/Library/Application Support/crow/sounds/ also works.');
  }

  async function uploadCustomSound(file) {
    try {
      const res = await fetch('/sounds', {
        method: 'POST',
        headers: { 'X-Filename': encodeURIComponent(file.name) },
        body: file,
        credentials: 'same-origin',
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        alertModal(body.error || ('Upload failed (' + res.status + ')'));
        return;
      }
      applySoundLibraryFromUpload(body);
    } catch (err) {
      alertModal('Upload failed: ' + (err.message || err));
    }
  }

  async function removeCustomSound(name) {
    if (!(await confirmModal('Remove “' + name + '”? Events that use it will fall back to a default sound.',
        { title: 'Remove sound', okLabel: 'Remove', danger: true }))) return;
    try {
      const res = await rpc('notifications-remove-sound', { name: name });
      applySoundLibraryFromGet(res && res.notifications);
    } catch (err) {
      alertModal('Remove failed: ' + (err.message || err));
    }
  }

  function applySoundLibraryFromUpload(sound) {
    if (!sound || !sound.name) return;
    customSounds = customSounds.filter((s) => s.name !== sound.name).concat([sound]);
    if (availableSounds.indexOf(sound.name) < 0) availableSounds = availableSounds.concat([sound.name]);
    if (window.crowSound && window.crowSound.setCustomSounds) {
      window.crowSound.setCustomSounds(customSounds);
    }
    S.render();
  }

  function applySoundLibraryFromGet(n) {
    if (!n) return;
    availableSounds = Array.isArray(n.available_sounds) && n.available_sounds.length
      ? n.available_sounds : BUILT_IN_SOUNDS.slice();
    customSounds = Array.isArray(n.custom_sounds) ? n.custom_sounds : [];
    if (window.crowSound && window.crowSound.setCustomSounds) {
      window.crowSound.setCustomSounds(customSounds);
    }
    S.render();
  }

  // Sound selector with an inline preview button (Web Audio synth, see
  // previewSound). Bound to conf.soundName like the desktop picker (CROW-593).
  function soundField(conf) {
    const wrap = el('div', 'st-sound-row');
    const sel = el('select', 'st-select');
    const names = availableSounds.slice();
    // Keep a stored custom/missing name selectable so Save doesn't silently
    // rewrite it to the first built-in.
    if (conf.soundName && names.indexOf(conf.soundName) < 0) names.push(conf.soundName);
    for (const s of names) {
      const o = el('option', null, s);
      o.value = s;
      if (conf.soundName === s) o.selected = true;
      sel.appendChild(o);
    }
    sel.onchange = () => { conf.soundName = sel.value; S.markDirty(); };
    const btn = el('button', 'action-btn', '▶ Preview');
    btn.type = 'button';
    btn.onclick = () => previewSound(sel.value);
    wrap.appendChild(sel);
    wrap.appendChild(btn);
    return S.field('Sound', wrap,
      'Preview of a built-in is a synthesized approximation; custom sounds play the uploaded file.');
  }

  // ---- Spoken notifications (voice spike) ---------------------------------
  // The voice list comes from the *client* (speechSynthesis.getVoices()), which
  // fills in asynchronously — re-render once when it arrives.
  let _voiceRerenderArmed = false;
  function voiceApi() { return window.crowVoice || null; }
  function voiceDefault(raw) {
    return (window.crowVoiceDefaultFor && window.crowVoiceDefaultFor(raw)) || { enabled: true, template: '{title}' };
  }
  // Speak with the form's *unsaved* globals so Preview reflects what you're editing.
  function previewSpeak(n, text) {
    const v = voiceApi();
    if (!v || !text) return;
    v.speak(text, {
      voiceName: n.voiceName || null,
      rate: typeof n.voiceRate === 'number' ? n.voiceRate : 1,
      volume: typeof n.voiceVolume === 'number' ? n.voiceVolume : 1,
      interrupt: true,
    });
  }
  function rangeField(label, n, key, min, max, step, dflt, help) {
    const wrap = el('div', 'st-sound-row');
    const input = el('input', 'st-range');
    input.type = 'range';
    input.min = String(min); input.max = String(max); input.step = String(step);
    const cur = typeof n[key] === 'number' ? n[key] : dflt;
    input.value = String(cur);
    const out = el('span', 'st-perm-status', cur.toFixed(2));
    input.oninput = () => {
      n[key] = parseFloat(input.value);
      out.textContent = n[key].toFixed(2);
      S.markDirty();
    };
    wrap.appendChild(input);
    wrap.appendChild(out);
    return S.field(label, wrap, help);
  }
  function voiceSelectField(n) {
    const v = voiceApi();
    const voices = v ? v.voices() : [];
    if (v && voices.length === 0 && !_voiceRerenderArmed) {
      _voiceRerenderArmed = true;
      // render() builds a fresh modal when none is open, so an unguarded call
      // here would resurrect a Settings the user closed (or discarded) before
      // the voice list arrived. Only repaint a modal that is still up; a later
      // open renders with the voices already loaded (review of #1473). Armed
      // once per page: the listener stays registered, so it also repaints an
      // open modal if the OS voice list changes later.
      v.onVoices(() => {
        if (!(window.settingsIsOpen && window.settingsIsOpen())) return;
        try { S.render(); } catch (_) {}
      });
    }
    const sel = el('select', 'st-select');
    const def = el('option', null, 'System default');
    def.value = '';
    sel.appendChild(def);
    // Group the user's language first; novelty voices sort in with the rest.
    const lang = (navigator.language || 'en').slice(0, 2).toLowerCase();
    const sorted = voices.slice().sort((a, b) => {
      const al = a.lang.toLowerCase().startsWith(lang) ? 0 : 1;
      const bl = b.lang.toLowerCase().startsWith(lang) ? 0 : 1;
      return al - bl || a.name.localeCompare(b.name);
    });
    const names = new Set();
    for (const voice of sorted) {
      if (names.has(voice.name)) continue;
      names.add(voice.name);
      const o = el('option', null, voice.name + ' (' + voice.lang + ')' + (voice.default ? ' — default' : ''));
      o.value = voice.name;
      if (n.voiceName === voice.name) o.selected = true;
      sel.appendChild(o);
    }
    // Keep a stored name this client doesn't have, so Save doesn't drop it.
    if (n.voiceName && !names.has(n.voiceName)) {
      const o = el('option', null, n.voiceName + ' (not on this device)');
      o.value = n.voiceName; o.selected = true;
      sel.appendChild(o);
    }
    sel.onchange = () => {
      if (sel.value) n.voiceName = sel.value; else delete n.voiceName;
      S.markDirty();
    };
    return S.field('Voice', sel,
      'Voices come from this device (macOS: System Settings → Accessibility → Spoken Content to add more). Each device that has Crow open speaks with its own voices.');
  }
  function voiceGlobalSection(body, n) {
    body.appendChild(S.group('Voice'));
    const v = voiceApi();
    if (!v || !v.supported()) {
      body.appendChild(el('div', 'st-help', 'Speech isn\u2019t available in this browser.'));
    }
    body.appendChild(S.toggleField('Speak notifications', n, 'voiceEnabled',
      'Say what happened ("crow 1078 needs you") instead of an anonymous chime. Per-event wording is below.'));
    body.appendChild(voiceSelectField(n));
    body.appendChild(rangeField('Rate', n, 'voiceRate', 0.5, 2, 0.05, 1, '1.00 is normal speed.'));
    body.appendChild(rangeField('Volume', n, 'voiceVolume', 0, 1, 0.05, 1));
    body.appendChild(S.toggleField('Chime before speaking', n, 'chimeBeforeVoice',
      'Off: the voice replaces the event\u2019s sound. On: play the sound, then speak.'));
    const row = el('div', 'st-sound-row');
    const btn = el('button', 'action-btn', '\u25B6 Preview voice');
    btn.type = 'button';
    btn.onclick = () => previewSpeak(n, window.crowVoicePreviewText
      ? window.crowVoicePreviewText('agentWaiting') : 'Crow needs you');
    row.appendChild(btn);
    body.appendChild(S.field('', row));
  }
  // Per-event: a Speak toggle showing the *resolved* value (absent = the event's
  // default — only an explicit change is written) and a template with Preview.
  function voiceEventFields(body, raw, conf, n) {
    const d = voiceDefault(raw);
    const row = el('label', 'st-switch-row');
    const input = el('input', 'st-switch');
    input.type = 'checkbox';
    input.checked = typeof conf.voiceEnabled === 'boolean' ? conf.voiceEnabled : d.enabled;
    input.onchange = () => { conf.voiceEnabled = input.checked; S.markDirty(); };
    row.appendChild(input);
    row.appendChild(el('span', 'st-switch-label', 'Speak'));
    const f = el('div', 'st-field');
    f.appendChild(row);
    body.appendChild(f);

    const wrap = el('div', 'st-sound-row');
    const tpl = el('input', 'st-input');
    tpl.type = 'text';
    tpl.maxLength = 200;
    tpl.placeholder = d.template;
    tpl.value = typeof conf.voiceTemplate === 'string' ? conf.voiceTemplate : '';
    tpl.oninput = () => {
      if (tpl.value.trim()) conf.voiceTemplate = tpl.value; else delete conf.voiceTemplate;
      S.markDirty();
    };
    const btn = el('button', 'action-btn', '\u25B6 Preview');
    btn.type = 'button';
    btn.onclick = () => previewSpeak(n, window.crowVoicePreviewText
      ? window.crowVoicePreviewText(raw, tpl.value.trim() || d.template) : (tpl.value || d.template));
    wrap.appendChild(tpl);
    wrap.appendChild(btn);
    body.appendChild(S.field('Spoken text', wrap,
      'Placeholders: {session} {repo} {pr} {event} {title} {body}. Leave empty for the default.'));
  }

  function renderNotifications(body) {
    S.cfg.notifications = S.cfg.notifications || {};
    const n = S.cfg.notifications;
    body.appendChild(S.group('Global'));
    body.appendChild(S.toggleField('Mute everything', n, 'globalMute', 'Suppresses all sounds and system notifications.'));
    body.appendChild(S.toggleField('Enable sound', n, 'soundEnabled'));
    body.appendChild(S.toggleField('Enable system notifications', n, 'systemNotificationsEnabled'));
    body.appendChild(browserNotifRow());
    body.appendChild(customSoundLibrary());
    voiceGlobalSection(body, n);

    for (const [raw, conf] of ensureAllEvents(n)) {
      body.appendChild(S.group(EVENT_LABELS[raw] || raw));
      body.appendChild(S.toggleField('Enabled', conf, 'enabled', EVENT_HINTS[raw]));
      body.appendChild(S.toggleField('Play sound', conf, 'soundEnabled'));
      body.appendChild(S.toggleField('System notification', conf, 'systemNotificationEnabled'));
      body.appendChild(soundField(conf));
      voiceEventFields(body, raw, conf, n);
    }
  }

  // Browser-notification permission control. The Notification API needs an
  // explicit grant; surface the live state + a button to request it (used by
  // app.js's showEventNotification). Also covers the Tauri webview
  // (CROW-593).
  function browserNotifRow() {
    const supported = typeof window !== 'undefined' && 'Notification' in window;
    const wrap = el('div', 'st-sound-row');
    const btn = el('button', 'action-btn', 'Enable browser notifications');
    btn.type = 'button';
    const status = el('span', 'st-perm-status', '');
    function refresh() {
      if (!supported) { status.textContent = 'Not supported in this browser'; btn.disabled = true; btn.textContent = 'Unavailable'; return; }
      // The Notification API only works in a secure context (HTTPS or
      // localhost). Over plain http:// on a LAN IP, Chrome reports 'denied' and
      // won't prompt — surface that as the real cause, not a user block.
      if (typeof window !== 'undefined' && window.isSecureContext === false) {
        status.textContent = 'Needs HTTPS or a localhost URL — this origin (' + location.host + ') is insecure';
        btn.disabled = true; btn.textContent = 'Unavailable (insecure origin)';
        return;
      }
      const p = Notification.permission;
      status.textContent = 'Permission: ' + p;
      btn.disabled = p === 'granted' || p === 'denied';
      btn.textContent = p === 'granted' ? 'Enabled'
        : p === 'denied' ? 'Blocked — re-enable via the site lock icon → Notifications'
        : 'Enable browser notifications';
    }
    btn.onclick = () => { if (supported) Notification.requestPermission().then(refresh); };
    refresh();
    wrap.appendChild(btn);
    wrap.appendChild(status);
    return S.field('Browser notifications', wrap,
      'Grant the browser permission to show desktop popups when a session finishes or needs attention. Also applies inside the Tauri desktop app.');
  }

  // eventSettings may be a Swift enum-keyed dict (encoded as [k, v, k, v, ...])
  // or a plain object; return [rawValue, configRef] pairs whose config objects
  // are live references into cfg (so edits round-trip on re-stringify).
  function eventEntries(es) {
    const out = [];
    if (Array.isArray(es)) {
      for (let i = 0; i + 1 < es.length; i += 2) out.push([es[i], es[i + 1]]);
    } else if (es && typeof es === 'object') {
      for (const k of Object.keys(es)) out.push([k, es[k]]);
    }
    return out;
  }

  // Return live [rawValue, configRef] pairs for ALL five canonical events in a
  // stable order, materializing any the config omits with their default sound.
  // New entries are pushed into eventSettings (in its existing array/object
  // shape) so they persist on save without marking the form dirty on open.
  function ensureAllEvents(n) {
    const existing = {};
    for (const [raw, conf] of eventEntries(n.eventSettings)) existing[raw] = conf;
    if (n.eventSettings == null) n.eventSettings = []; // default to Swift array form
    const asObject = !Array.isArray(n.eventSettings);
    for (const raw of EVENT_ORDER) {
      if (existing[raw]) continue;
      const conf = {
        enabled: true, soundEnabled: true, systemNotificationEnabled: true,
        soundName: EVENT_DEFAULT_SOUND[raw] || 'Glass',
      };
      existing[raw] = conf;
      if (asObject) n.eventSettings[raw] = conf;
      else n.eventSettings.push(raw, conf);
    }
    return EVENT_ORDER.map((raw) => [raw, existing[raw]]);
  }

  T.notifications = renderNotifications;
  T.applySoundLibraryFromGet = applySoundLibraryFromGet;
})();
