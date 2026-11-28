// Runtime check of the HTML dialogs: replay the scripts Ruby sent them in the tests
// (DUMP_JS dumps), then click every button and change every input. Any JS error = a finding.
// usage: NODE_PATH=/tmp/jsd/node_modules node scripts/js_check.js /tmp/jsdump/*.json
const fs = require('fs'), path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');
const htmlDir = path.join(__dirname, '..', 'src', 'dmacc_wall_framer', 'html');
let problems = 0, runs = 0;
for (const dump of process.argv.slice(2)) {
  const dialogs = JSON.parse(fs.readFileSync(dump, 'utf8'));
  for (const d of dialogs) {
    const file = path.join(htmlDir, d.file);
    if (!fs.existsSync(file)) continue;
    const errs = [];
    const vc = new VirtualConsole();
    vc.on('jsdomError', e => errs.push(String(e.detail || e.message || e)));
    vc.on('error', e => errs.push(String(e)));
    const calls = [];
    const dom = new JSDOM(fs.readFileSync(file, 'utf8'), {
      runScripts: 'dangerously', virtualConsole: vc, pretendToBeVisual: true,
      beforeParse(w) {
        w.sketchup = new Proxy({}, { get: (_t, n) => (...a) => calls.push([n, a]) });
        w.alert = () => {}; w.confirm = () => true; w.prompt = () => '';
        w.scrollTo = () => {}; w.HTMLElement.prototype.scrollIntoView = function () {};
      }
    });
    const w = dom.window;
    w.addEventListener('error', e => errs.push(`${e.message} @${e.lineno}`));
    const first = d.scripts.findIndex(s => s.startsWith('load('));
    for (const s of d.scripts.slice(Math.max(first, 0))) {
      try { w.eval(s); } catch (e) { errs.push(`replay ${s.slice(0, 40)}: ${e.message}`); }
      runs++;
    }
    // poke everything
    for (const el of w.document.querySelectorAll('button, input, select, a, [onclick]')) {
      try {
        if (el.tagName === 'INPUT' || el.tagName === 'SELECT') {
          el.dispatchEvent(new w.Event('input', { bubbles: true }));
          el.dispatchEvent(new w.Event('change', { bubbles: true }));
          el.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        } else el.click();
      } catch (e) { errs.push(`click ${el.textContent.trim().slice(0, 30)}: ${e.message}`); }
    }
    const uniq = [...new Set(errs)];
    if (uniq.length) {
      problems += uniq.length;
      console.log(`FINDING ${path.basename(dump)} ${d.file}: ${uniq.slice(0, 6).join(' | ')}`);
    }
    const bad = calls.filter(([n]) => !/^[a-z_]+$/.test(n));
    if (bad.length) console.log(`FINDING ${d.file}: odd callback names ${bad.map(c => c[0])}`);
    w.close();
  }
}
console.log(problems ? `${problems} JS problems (${runs} scripts replayed)` : `ALL PASSED (${runs} scripts replayed)`);
