'use strict';

// Adapted from Wink's hterm integration. Keep this independent of native
// file APIs: terminal output (including SSH output) is untrusted.
(() => {
  const previousAPC = hterm.VT.ESC['_'];
  hterm.VT.CC1['\x9f'] = hterm.VT.ESC['_'] = function(state) {
    if (!this.terminal.graphics) {
      if (previousAPC) previousAPC.call(this, state);
      return;
    }
    state.resetArguments();
    const parseAPC = function(state) {
      if (!this.parseUntilStringTerminator_(state)) return;
      if (state.func === parseAPC) return;
      const body = state.args[0];
      if (body[0] !== 'G') return;
      const wait = this.terminal.graphics.command(body.slice(1));
      if (wait) {
        const rest = state.peekRemainingBuf();
        state.advance(rest.length);
        this.terminal.pauseGraphicsOutput(rest, wait);
      }
    };
    state.func = parseAPC;
  };

  const previousWindowOp = hterm.VT.CSI['t'];
  hterm.VT.CSI['t'] = function(state) {
    const graphics = this.terminal.graphics;
    const op = Number(state.args[0]);
    if (!graphics || ![14, 16, 18].includes(op)) {
      if (previousWindowOp) previousWindowOp.call(this, state);
      return;
    }
    const px = graphics.pixelSizes(), size = this.terminal.screenSize;
    const reply = {
      14: `\x1b[4;${px.height};${px.width}t`,
      16: `\x1b[6;${px.cellH};${px.cellW}t`,
      18: `\x1b[8;${size.height};${size.width}t`,
    }[op];
    this.terminal.io.sendString(reply);
  };

  window.installKittyGraphics = function(term) {
    if (term.graphics) return;
    term.vt.maxStringSequence = 1 << 20;
    // Blink's bundled parser retains its own dispatch table. Route graphics
    // entries explicitly while preserving every other terminal operation.
    const dispatch = term.vt.dispatch;
    term.vt.dispatch = function(type, code, state) {
      if ((type === 'ESC' && code === '_') ||
          (type === 'CSI' && code === 't') ||
          (type === 'CC1' && code === '\x9f' && this.enable8BitControl)) {
        return hterm.VT[type][code].call(this, state);
      }
      return dispatch.call(this, type, code, state);
    };
    term.graphics = new BlinkGraphics(term, {
      send: (data) => term.io.sendString(data),
      readFile: async () => null,
    });
    const interpret = term.interpret;
    const held = [];
    let paused = false;
    term.pauseGraphicsOutput = function(rest, wait) {
      if (rest) held.unshift(rest);
      paused = true;
      Promise.resolve(wait).catch(() => {}).then(() => {
        paused = false;
        while (!paused && held.length) term.interpret(held.shift());
      });
    };
    term.interpret = function(data) {
      if (paused) { held.push(data); return; }
      interpret.call(this, data);
      if (this.graphics.images.size) this.graphics.scheduleRender();
    };
  };
})();
