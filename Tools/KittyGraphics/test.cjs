// Local Chromium integration tests against Blink's actual hterm bundle.
// NODE_PATH=/path/to/node_modules CHROME_PATH=/path/to/chrome node Tools/KittyGraphics/test.cjs
const puppeteer = require('puppeteer');
const path = require('node:path');
const assert = require('node:assert/strict');
(async () => {
  const browser = await puppeteer.launch({headless: true, executablePath: process.env.CHROME_PATH || undefined});
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    await page.goto('file://' + path.resolve(__dirname, 'harness.html'));
    for (const name of ['hterm_all.min.js', 'hterm_all.patches.js', 'kitty.js', 'kitty-integration.js']) {
      await page.addScriptTag({path: path.resolve(__dirname, '../../Resources', name)});
    }
    await page.evaluate(() => new Promise(resolve => lib.init(resolve)));
    await page.evaluate(() => new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('terminal setup timeout')), 8000);
      hterm.defaultStorage = new lib.Storage.Memory();
      const prefs = new hterm.PreferenceManager('test');
      prefs.set('audible-bell-sound', '');
      prefs.set('receive-encoding', 'raw');
      window.replies = [];
      window.webkit = {messageHandlers: {wkScroller: {postMessage() {}}}};
      window.term = window.t = new hterm.Terminal('test');
      term.onTerminalReady = () => {
        window.installKB(term, term.scrollPort_.screen_);
        term.io.sendString = s => replies.push(s);
        term.vt.characterEncoding = 'raw';
        installKittyGraphics(term);
        clearTimeout(timeout);
        resolve();
      };
      term.decorate(document.getElementById('terminal'));
    }));
    const passed = await page.evaluate(async () => {
      const passed = [];
      const check = (condition, name) => { if (!condition) throw new Error(name); passed.push(name); };
      const settle = async () => { await new Promise(r => setTimeout(r, 80)); term.scrollPort_.redraw_(); term.graphics.render(); };
      const send = body => term.interpret('\x1b_G' + body + '\x1b\\');
      const text = () => term.screen_.rowsArray.map(r => r.nodes.map(n => n.txt).join('')).join('\n');
      const shown = () => [...term.graphics.above.querySelectorAll('canvas')].filter(c => c.style.display !== 'none');
      const red = canvas => { const p = canvas.getContext('2d').getImageData(Math.floor(canvas.width/2), Math.floor(canvas.height/2), 1, 1).data; return p[0] === 255 && p[1] === 0 && p[2] === 0 && p[3] === 255; };

      term.interpret('\x1b_Ga=T,f=32,s=1,v=1,i=42;');
      term.interpret('/wAA/w==\x1b\\AFTER');
      term.interpret('LATER');
      await settle();
      check(term.graphics.images.has(42), 'split APC upload');
      check(replies.splice(0).some(s => s.includes('i=42;OK')), 'upload acknowledgment');
      check(text().includes('AFTERLATER'), 'async decode preserves output order');
      check(shown().length === 1, 'placement is visible');
      check(red(shown()[0]), 'canvas contains decoded red pixels');
      check(term.screen_.cursorPosition.column === 11, 'image cursor advance and following text');

      send('a=q,t=f,i=43;L2V0Yy9wYXNzd2Q='); await settle();
      check(replies.splice(0).some(s => s.includes('EBADF')), 'local files are inaccessible');
      term.interpret('\x1b[14t\x1b[16t\x1b[18t');
      check(replies.splice(0).length === 3, 'window and cell size replies');
      send('a=a,i=42');
      check(replies.splice(0).some(s => s.includes('ENOTSUP')), 'unsupported animation reports error');

      term.interpret('\x1b[?1049h'); await settle();
      check(shown().length === 0, 'primary image hidden on alternate screen');
      term.interpret('\x1b[?1049l'); await settle();
      check(shown().length === 1, 'primary image restored after alternate screen');

      // Scroll the image into scrollback, then drive the same callback the
      // native UIScrollView uses to bring its anchor row back into view.
      term.interpret('\r\n'.repeat(term.screenSize.height + 4)); await settle();
      const sp = term.scrollPort_;
      sp.scroller_.reportScroll(0, term.scrollbackRows_.length * sp.characterSize.height, false);
      await settle();
      check(shown().length === 0, 'image outside viewport is hidden');
      sp.scroller_.reportScroll(0, 0, false); await settle();
      check(shown().length === 1 && red(shown()[0]), 'scrollback anchor redraws after native scroll');
      send('a=d,d=I,i=42'); await settle();
      check(!term.graphics.images.has(42) && shown().length === 0, 'deletion releases image and canvas');

      term.reset(); sp.scroller_.reportScroll(0, term.scrollbackRows_.length * sp.characterSize.height, false);
      send('a=T,U=1,f=32,s=1,v=1,i=66051,c=2,r=1;/wAA/w=='); await settle();
      check(shown().length === 0, 'virtual placement is invisible without placeholders');
      term.interpret('\x1b[38;2;1;2;3m\u{10eeee}\u0305\u0305\u{10eeee}\u0305\u030d\x1b[39mX'); await settle();
      check(term.graphics.phPool.some(c => c.style.display !== 'none'), 'tmux-style RGB placeholders render');
      const ph = term.graphics.phPool.find(c => c.style.display !== 'none');
      check(red(ph), 'placeholder canvas contains red image pixels');
      check(term.screen_.cursorPosition.column === 3, 'placeholders consume one terminal cell each');
      check(text().includes('X'), 'text following placeholders is preserved');
      const originalWidth = ph.width;
      check(term.scrollPort_._renderDom.textContent.includes('X'), 'React text renderer remains active');
      term.setFontSize(20); await settle();
      check(ph.width > originalWidth && red(ph), 'font resize resizes placeholder canvas');
      term.clearHome(); await settle();
      check(term.graphics.phPool.every(c => c.style.display === 'none'), 'clearing placeholder text hides image');

      // PNG upload larger than hterm's old 1024 byte string cap, with Kitty
      // m=1/m=0 chunks; query must not retain the decoded image.
      const png = document.createElement('canvas'); png.width = png.height = 64;
      const ctx = png.getContext('2d'), pixels = ctx.createImageData(64,64);
      let random = 123456789;
      for (let i=0; i<pixels.data.length; i++) { random ^= random << 13; random ^= random >>> 17; random ^= random << 5; pixels.data[i] = random & 255; }
      ctx.putImageData(pixels,0,0);
      const payload = png.toDataURL('image/png').split(',')[1];
      check(payload.length > 4096, 'PNG fixture exceeds historical string cap');
      send('a=q,f=100,i=90,m=1;' + payload.slice(0,4096));
      send('m=0;' + payload.slice(4096)); await settle();
      check(replies.splice(0).some(s => s.includes('i=90;OK')), 'chunked PNG query decodes successfully');
      check(!term.graphics.images.has(90), 'query does not retain image');
      return passed;
    });
    // Exercise the real app startup and both native output entry points too.
    const app = await browser.newPage();
    app.on('pageerror', error => errors.push(String(error)));
    await app.evaluateOnNewDocument(() => {
      window.nativeMessages = [];
      window.webkit = {messageHandlers: {
        wkScroller: {postMessage() {}},
        interOp: {postMessage(message) {nativeMessages.push(message);}},
      }};
    });
    await app.goto('file://' + path.resolve(__dirname, '../../Resources/term.html'));
    await app.addStyleTag({content: 'html {height:100%}'});
    await app.evaluate(() => new Promise(resolve => lib.init(resolve)));
    await app.evaluate(() => { term_setupDefaults(); term_setup(false); });
    await app.waitForFunction(() => nativeMessages.some(m => m.op === 'terminalReady'));
    const startup = await app.evaluate(async () => {
      const ready = nativeMessages.find(m => m.op === 'terminalReady');
      term_write('\x1b_Ga=T,f=32,s=1,v=1,i=99,c=8,r=4;/wAA/w==\x1b\\');
      term_write_b64(btoa('NATIVE OUTPUT'));
      await new Promise(r => setTimeout(r, 150));
      t.graphics.render();
      term_write('\x1b[8;1H\x1b_Ga=T,f=32,s=1,v=1,i=100,c=8,r=4,z=-1;AP8A/w==\x1b\\');
      await new Promise(r => setTimeout(r, 80));
      t.graphics.render();
      return {below: t.graphics.below.querySelector('canvas')?.parentNode === t.graphics.below, bgColor: ready.data.bgColor, currentBackground: _colorComponents(t.scrollPort_.screen_.style.backgroundColor), text: t.screen_.rowsArray.map(r => r.nodes.map(n => n.txt).join('')).join(''),
        image: t.graphics.images.has(99), canvas: !!t.graphics.above.querySelector('canvas'),
        replies: nativeMessages.filter(m => m.op === 'sendString').map(m => m.data.string)};
    });
    assert.ok(startup.bgColor.length >= 3 && startup.bgColor.every(Number.isFinite), 'native background color is valid');
    assert.deepEqual(startup.currentBackground, startup.bgColor, 'native theme readback stays valid after graphics installation');
    assert.ok(startup.text.includes('NATIVE OUTPUT'), 'base64 native output stays queued after image');
    assert.ok(startup.below, 'negative-z placement uses below-text layer');
    assert.ok(startup.image && startup.canvas, 'actual app startup renders graphics');
    assert.ok(startup.replies.some(r => r.includes('i=99;OK')), 'native input bridge receives image acknowledgment');
    const screenshot = await app.screenshot(process.env.KITTY_SCREENSHOT ? {path: process.env.KITTY_SCREENSHOT} : {});
    const composed = await app.evaluate(async b64 => {
      const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
      const bitmap = await createImageBitmap(new Blob([bytes], {type: 'image/png'}));
      const canvas = document.createElement('canvas'); canvas.width = bitmap.width; canvas.height = bitmap.height;
      const ctx = canvas.getContext('2d'); ctx.drawImage(bitmap, 0, 0); bitmap.close();
      return {above: [...ctx.getImageData(20,20,1,1).data], below: [...ctx.getImageData(20,140,1,1).data]};
    }, Buffer.from(screenshot).toString('base64'));
    assert.deepEqual(composed.above, [255,0,0,255], 'above-text image is visible in composed page');
    assert.deepEqual(composed.below, [0,255,0,255], 'below-text image is visible through React background');
    assert.deepEqual(errors, [], 'no browser exceptions');
    console.log(`${passed.length + 9} Kitty graphics browser checks passed`);
    for (const name of passed) console.log('PASS ' + name);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
