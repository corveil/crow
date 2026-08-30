'use strict';
// Shared jsdom loader (CROW-1155). Concatenates every classic client script in
// index.html order so a test that used to `vm.runInContext` the monolithic
// app.js still sees the same global object. Sequential eval in Node's vm would
// NOT share `let`/`const` across scripts; concatenation matches the original
// single-script harness and is close enough to the browser's shared global
// lexical environment for these tests.
const fs = require('fs');
const path = require('path');

const WEB = path.join(__dirname, '../Sources/CrowDaemon/Resources/web') + '/';

function isSettingsScript(name) {
  return name === 'settings.js' || name.startsWith('settings-');
}

function clientScriptFiles({ includeSettings = false } = {}) {
  const html = fs.readFileSync(WEB + 'index.html', 'utf8');
  const names = [];
  const re = /<script src="\/([^"]+\.js)"><\/script>/g;
  let m;
  while ((m = re.exec(html))) {
    const name = m[1];
    if (name.startsWith('xterm/')) continue;
    if (!includeSettings && isSettingsScript(name)) continue;
    names.push(name);
  }
  return names;
}

function loadClientSource(opts) {
  return clientScriptFiles(opts)
    .map((name) => fs.readFileSync(WEB + name, 'utf8'))
    .join('\n');
}

function loadSettingsSource() {
  return clientScriptFiles({ includeSettings: true })
    .filter(isSettingsScript)
    .map((name) => fs.readFileSync(WEB + name, 'utf8'))
    .join('\n');
}

module.exports = { WEB, clientScriptFiles, loadClientSource, loadSettingsSource, isSettingsScript };
