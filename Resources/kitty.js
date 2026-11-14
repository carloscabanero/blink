'use strict';

// Kitty graphics protocol, ported from Tanguy de Courson’s Wink (GPL-3.0).
// Blink adapter uses React row models and native-scroller viewport geometry.
// Spec: https://sw.kovidgoyal.net/kitty/graphics-protocol/
//
// Commands arrive as APC sequences (ESC _ G <keys>;<base64> ESC \) that
// kitty-integration.js hands to command(). Anything that needs decoding returns a promise,
// and kitty-integration.js holds back the rest of the output until it settles, so images
// land at the cursor position they were sent at and replies (e.g. to a=q)
// come before the replies to whatever the program sent next.
//
// Placements are anchored to hterm row models, so they scroll with the text
// and survive screen switches, and are drawn as canvases on two layers:
// below the text (z < 0) and above it. Unicode placeholders (U+10EEEE plus
// row/column diacritics, image id in the foreground color) are found by
// scanning the visible rows, which is what lets tmux and others move images
// around as ordinary text.
//
// Not supported: animation (a=f, a=a, a=c).

(() => {

class BlinkGraphics {
  constructor(term, {send, readFile}) {
    this.t = term;
    this.send = send;         // (string) => write a reply to the program
    this.readFile = readFile; // (medium, path, offset, size) => Promise<Uint8Array|null>
    this.images = new Map();  // id -> image; anonymous images get negative ids
    this.upload = null;       // chunked transmission in progress
    this.seq = 0;
    this.anonymous = 0;
    this.nextId = 0x7f000000; // ids we hand out for I= image numbers
    this.bytesUsed = 0;
    this.renderQueued = false;
    this.phPool = [];         // canvases for Unicode placeholder runs

    this.installLayers();
    this.installHooks();
  }

  // --- Commands ---------------------------------------------------------

  /** Handles one APC G command; returns a promise if output must wait. */
  command(body) {
    const semi = body.indexOf(';');
    const keys = parseKeys(semi < 0 ? body : body.slice(0, semi));
    const payload = semi < 0 ? '' : body.slice(semi + 1);

    if (this.upload) {
      const isChunk = Object.keys(keys).every((k) => k === 'm' || k === 'q');
      if (isChunk) {
        const u = this.upload;
        u.payload.push(payload);
        u.length += payload.length;
        if (keys.q !== undefined) u.keys.q = keys.q;
        if (u.length > BlinkGraphics.MAX_BASE64) {
          this.upload = null;
          this.reply(u.keys, 'EFBIG:Image data too large');
          return null;
        }
        if (keys.m === 1) return null;
        this.upload = null;
        return this.run(u.keys, u.payload.join(''));
      }
      this.upload = null; // abandoned: a different command interrupted it
    }
    if (keys.m === 1) {
      this.upload = {keys, payload: [payload], length: payload.length};
      return null;
    }
    return this.run(keys, payload);
  }

  run(keys, payload) {
    if (keys.i && keys.I) {
      this.reply(keys, 'EINVAL:Must not specify both i and I');
      return null;
    }
    switch (keys.a || 't') {
      case 't': case 'T': case 'q':
        return this.transmit(keys, payload);
      case 'p':
        this.put(keys, null, this.cursorAnchor());
        return null;
      case 'd':
        this.remove(keys);
        return null;
      default:
        this.reply(keys, 'ENOTSUP:Animation is not supported');
        return null;
    }
  }

  transmit(keys, payload) {
    const anchor = this.cursorAnchor(); // where the image goes, captured now
    return (async () => {
      let decoded;
      try {
        let bytes = await this.load(keys, payload);
        if (keys.o === 'z') bytes = await inflate(bytes);
        decoded = await decodeImage(keys, bytes);
      } catch (e) {
        this.reply(keys, e instanceof GraphicsError ? e.message : `EINVAL:${e.message || e}`);
        return;
      }
      if (keys.a === 'q') {
        decoded.bitmap.close();
        this.reply(keys, 'OK');
        return;
      }
      const image = this.store(keys, decoded);
      if (keys.a === 'T') this.put(keys, image, anchor);
      else this.reply(keys, 'OK', image);
    })();
  }

  async load(keys, payload) {
    const medium = keys.t || 'd';
    if (medium === 'd') return base64Bytes(payload);
    if (!'fts'.includes(medium)) throw new GraphicsError('EINVAL', 'Unknown transmission medium');
    const path = new TextDecoder().decode(base64Bytes(payload));
    const data = await this.readFile(medium, path, keys.O || 0, keys.S || 0);
    // One answer for every failure, so a remote program can't probe local files.
    if (!data) throw new GraphicsError('EBADF', 'Failed to read image file');
    return data;
  }

  store(keys, decoded) {
    let id;
    if (keys.i) {
      id = keys.i;
      this.deleteImage(this.images.get(id)); // re-transmitting replaces it
    } else if (keys.I) {
      do id = this.nextId++; while (this.images.has(id));
    } else {
      id = -(++this.anonymous);
    }
    const image = Object.assign(decoded, {id, number: keys.I || 0, seq: ++this.seq, placements: new Map()});
    this.images.set(id, image);
    this.bytesUsed += image.bytes;
    this.enforceQuota(image);
    return image;
  }

  /** Creates a placement (a=p, or the display half of a=T). */
  put(keys, image, anchor) {
    image = image || this.findImage(keys);
    if (!image) {
      this.reply(keys, 'ENOENT:Image not found');
      return;
    }
    const pid = keys.p || 0;
    const p = {
      image, pid, key: pid ? `p${pid}` : `n${++this.seq}`, z: keys.z || 0,
      src: sourceRect(keys, image), c: keys.c || 0, r: keys.r || 0, X: keys.X || 0, Y: keys.Y || 0,
    };
    if (keys.U === 1) {
      if (keys.P) {
        this.reply(keys, 'EINVAL:A virtual placement cannot be relative');
        return;
      }
      p.virtual = true;
    } else if (keys.P) {
      const parent = this.findPlacement(keys.P, keys.Q || 0);
      if (!parent) {
        this.reply(keys, 'ENOPARENT:Parent placement not found');
        return;
      }
      let depth = 1;
      for (let q = parent; q; q = q.parent, depth++) {
        if (q.image === image && q.pid === pid && pid) {
          this.reply(keys, 'ECYCLE:Relative placement would form a cycle');
          return;
        }
        if (depth > 8) {
          this.reply(keys, 'ETOODEEP:Relative placement chain is too deep');
          return;
        }
      }
      Object.assign(p, {parent, H: keys.H || 0, V: keys.V || 0});
    } else {
      Object.assign(p, anchor);
    }
    this.layoutPlacement(p);

    const old = image.placements.get(p.key);
    if (old) this.dropPlacement(old);
    image.placements.set(p.key, p);
    if (!p.virtual && !p.parent && keys.C !== 1) this.moveCursorPast(p);
    this.reply(keys, 'OK', image);
    this.scheduleRender();
  }

  /** Size of a placement in CSS pixels and in cells. */
  layoutPlacement(p) {
    const {cw, ch, dpr} = this.metrics();
    const {w, h} = p.src;
    const X = p.X / dpr, Y = p.Y / dpr;
    let dw, dh, offX = X, offY = Y;
    if (p.c && p.r) {
      // Fit inside c×r cells without distortion, letterboxed.
      const boxW = p.c * cw - X, boxH = p.r * ch - Y;
      const scale = Math.min(boxW / w, boxH / h);
      dw = w * scale; dh = h * scale;
      offX += (boxW - dw) / 2; offY += (boxH - dh) / 2;
    } else if (p.c) {
      dw = p.c * cw; dh = dw * h / w;
    } else if (p.r) {
      dh = p.r * ch; dw = dh * w / h;
    } else {
      dw = w / dpr; dh = h / dpr; // image pixels are device pixels
    }
    Object.assign(p, {
      dw, dh, offX, offY,
      cols: p.c || Math.max(1, Math.ceil((X + dw) / cw - 1e-6)),
      rows: p.r || Math.max(1, Math.ceil((Y + dh) / ch - 1e-6)),
    });
  }

  /** After an image, the cursor goes right of its last row (like kitty). */
  moveCursorPast(p) {
    const t = this.t;
    for (let i = 1; i < p.rows; i++) t.lineFeed(); // scrolls when at the bottom
    t.setCursorColumn(Math.min(p.col + p.cols, t.screenSize.width - 1));
  }

  remove(keys) {
    this.upload = null; // a delete aborts any partial upload
    const d = keys.d || 'a';
    const free = d !== d.toLowerCase();
    const all = [...this.allPlacements()];
    const real = all.filter((p) => !p.virtual);
    const hits = (x, y) => (p) => this.coversCell(p, x, y);
    let victims = [];
    const images = new Set();
    switch (d.toLowerCase()) {
      case 'a': victims = real.filter((p) => this.onScreen(p)); break;
      case 'i': {
        const image = this.images.get(keys.i);
        if (image) {
          victims = [...image.placements.values()].filter((p) => !keys.p || p.pid === keys.p);
          if (free && !keys.p) images.add(image);
        }
        break;
      }
      case 'n': {
        const image = this.newestWithNumber(keys.I);
        if (image) {
          victims = [...image.placements.values()].filter((p) => !keys.p || p.pid === keys.p);
          if (free && !keys.p) images.add(image);
        }
        break;
      }
      case 'r':
        for (const image of this.images.values()) {
          if (image.id >= (keys.x || 0) && image.id <= (keys.y || 0)) {
            victims.push(...image.placements.values());
            if (free) images.add(image);
          }
        }
        break;
      case 'c': {
        const pos = this.t.screen_.cursorPosition;
        victims = real.filter(hits(pos.column + 1, pos.row + 1));
        break;
      }
      case 'p': victims = real.filter(hits(keys.x, keys.y)); break;
      case 'q': victims = real.filter((p) => p.z === (keys.z || 0) && this.coversCell(p, keys.x, keys.y)); break;
      case 'x': victims = real.filter(hits(keys.x, null)); break;
      case 'y': victims = real.filter(hits(null, keys.y)); break;
      case 'z': victims = real.filter((p) => p.z === (keys.z || 0)); break;
      case 'f': break; // animation frames: nothing to do
    }
    for (const p of victims) {
      this.dropPlacement(p);
      if (free) images.add(p.image);
    }
    for (const image of images) {
      if (image.placements.size === 0) this.deleteImage(image);
    }
    this.scheduleRender();
  }

  reply(keys, msg, image) {
    const ok = msg === 'OK';
    if ((ok && keys.q >= 1) || (!ok && keys.q >= 2)) return;
    const id = image && image.id > 0 ? image.id : keys.i;
    if (!id && !keys.I) return; // kitty only answers commands that carry an id
    const parts = [];
    if (id) parts.push(`i=${id}`);
    if (keys.I) parts.push(`I=${keys.I}`);
    if (keys.p) parts.push(`p=${keys.p}`);
    this.send(`\x1b_G${parts.join(',')};${msg}\x1b\\`);
  }

  // --- Bookkeeping ------------------------------------------------------

  * allPlacements() {
    for (const image of this.images.values()) yield* image.placements.values();
  }

  findImage(keys) {
    if (keys.i) return this.images.get(keys.i) || null;
    if (keys.I) return this.newestWithNumber(keys.I);
    return null;
  }

  newestWithNumber(number) {
    let best = null;
    for (const image of this.images.values()) {
      if (number && image.number === number && (!best || image.seq > best.seq)) best = image;
    }
    return best;
  }

  findPlacement(imageId, pid) {
    const image = this.images.get(imageId);
    if (!image) return null;
    if (pid) return image.placements.get(`p${pid}`) || null;
    return image.placements.values().next().value || null;
  }

  dropPlacement(p) {
    if (p.dropped) return;
    p.dropped = true;
    p.image.placements.delete(p.key);
    if (p.el) p.el.remove();
    // Relative placements live and die with their parent.
    for (const q of [...this.allPlacements()]) if (q.parent === p) this.dropPlacement(q);
  }

  deleteImage(image) {
    if (!image || !this.images.has(image.id)) return;
    for (const p of [...image.placements.values()]) this.dropPlacement(p);
    this.images.delete(image.id);
    this.bytesUsed -= image.bytes;
    image.bitmap.close();
  }

  /** Keeps decoded pixels under the quota: unplaced images go first, oldest first. */
  enforceQuota(keep) {
    if (this.bytesUsed <= BlinkGraphics.QUOTA) return;
    const victims = [...this.images.values()]
        .filter((i) => i !== keep)
        .sort((a, b) => (a.placements.size > 0) - (b.placements.size > 0) || a.seq - b.seq);
    for (const image of victims) {
      if (this.bytesUsed <= BlinkGraphics.QUOTA) break;
      this.deleteImage(image);
    }
  }

  cursorAnchor() {
    const screen = this.t.screen_;
    const pos = screen.cursorPosition;
    return {screen, row: screen.rowsArray[pos.row], col: pos.column};
  }

  /** Absolute row index of a placement's anchor row, or null if not shown. */
  anchorRow(p) {
    const t = this.t;
    if (!p.row || p.screen !== t.screen_) return null;
    const scrollback = t.scrollbackRows_, rows = p.screen.rowsArray;
    if (rows[p.row.n - scrollback.length] === p.row) return p.row.n;
    let i = rows.indexOf(p.row);
    if (i >= 0) return scrollback.length + i;
    if (p.screen === t.primaryScreen_) {
      if (scrollback[p.row.n] === p.row) return p.row.n;
      i = scrollback.lastIndexOf(p.row);
      if (i >= 0) return i;
    }
    p.gone = true; // its row scrolled out of existence
    return null;
  }

  /** Screen cells (0-based) a placement covers, or null if not on this screen. */
  screenCells(p) {
    const abs = this.anchorRow(p);
    if (abs == null) return null;
    const row = abs - this.t.scrollbackRows_.length;
    return {row, col: p.col, rows: p.rows, cols: p.cols};
  }

  onScreen(p) {
    const c = this.screenCells(p);
    return !!c && c.row + c.rows > 0 && c.row < this.t.screenSize.height;
  }

  /** x, y are 1-based screen coordinates; null means "any". */
  coversCell(p, x, y) {
    const c = this.screenCells(p);
    if (!c) return false;
    return (x == null || (x - 1 >= c.col && x - 1 < c.col + c.cols)) &&
           (y == null || (y - 1 >= c.row && y - 1 < c.row + c.rows));
  }

  /** Placements whose rows were cleared from `screen`. */
  clearScreen(screen) {
    for (const p of [...this.allPlacements()]) {
      if (p.virtual || p.screen !== screen) continue;
      if (p.row && screen.rowsArray.includes(p.row)) this.dropPlacement(p);
    }
    this.scheduleRender();
  }

  metrics() {
    const size = this.t.scrollPort_.characterSize;
    return {cw: size.width, ch: size.height, dpr: window.devicePixelRatio || 1};
  }

  /** Cell and window sizes in device pixels, for CSI 14/16 t and TIOCGWINSZ. */
  pixelSizes() {
    const {cw, ch, dpr} = this.metrics();
    const cellW = Math.round(cw * dpr), cellH = Math.round(ch * dpr);
    return {
      cellW, cellH,
      width: Math.round(cw * dpr * this.t.screenSize.width),
      height: Math.round(ch * dpr * this.t.screenSize.height),
    };
  }

  // --- Drawing ----------------------------------------------------------

  installLayers() {
    const doc = this.t.document_;
    const screen = this.t.scrollPort_.screen_;
    const layer = (z) => {
      const el = doc.createElement('div');
      el.style.cssText = `position: fixed; overflow: hidden; pointer-events: none; z-index: ${z};`;
      return el;
    };
    // Keep Blink's real screen background intact: native theme synchronization
    // reads it back from screen_.style.backgroundColor. The lower image layer
    // lives inside that background, underneath the React text layer.
    this.below = layer(0);
    this.above = layer(3);
    screen.insertBefore(this.below, screen.firstChild);
    doc.body.appendChild(this.above);
    screen.style.position = 'relative';
    screen.style.zIndex = '1';
    this.t.scrollPort_.rowNodes_.style.zIndex = '1';
    this.t.scrollPort_.rowNodes_.style.backgroundColor = 'transparent';
    if (this.t.cursorOverlayNode_) this.t.cursorOverlayNode_.style.zIndex = '2';
  }

  installHooks() {
    const t = this.t, sp = t.scrollPort_;
    const self = this;
    // Redraw images in the same pass hterm redraws rows (scrolling, resizes).
    const redraw = sp.redraw_;
    sp.redraw_ = function() {
      redraw.apply(this, arguments);
      self.render();
    };
    const clearHome = t.clearHome;
    t.clearHome = function(screen) {
      clearHome.apply(this, arguments);
      self.clearScreen(screen || this.screen_);
    };
    const setAlternateMode = t.setAlternateMode;
    t.setAlternateMode = function(state) {
      // Entering the alternate screen starts with a blank screen, images too.
      if (state && this.screen_ !== this.alternateScreen_) self.clearScreen(this.alternateScreen_);
      setAlternateMode.apply(this, arguments);
      self.scheduleRender();
    };
    const reset = t.reset;
    t.reset = function() {
      reset.apply(this, arguments);
      self.upload = null;
      for (const p of [...self.allPlacements()]) if (!p.virtual) self.dropPlacement(p);
      self.scheduleRender();
    };
  }

  /** Like hterm's own redraw scheduling (not rAF, which hidden tabs pause). */
  scheduleRender() {
    if (this.renderQueued) return;
    this.renderQueued = true;
    setTimeout(() => this.render(), 0);
  }

  render() {
    this.renderQueued = false;
    const t = this.t, sp = t.scrollPort_;
    const screenRect = sp.screen_.getBoundingClientRect();
    for (const layer of [this.below, this.above]) {
      Object.assign(layer.style, {
        left: `${screenRect.left}px`, top: `${screenRect.top}px`,
        width: `${sp.screen_.clientWidth}px`, height: `${sp.screen_.clientHeight}px`,
      });
    }
    // Blink keeps React row models; neither anchors nor placeholder metadata
    // should depend on React's asynchronously committed DOM.
    const top = sp.getTopRowIndex();
    const rows = [];
    const count = Math.min(sp.visibleRowCount, t.getRowCount() - top);
    for (let i = 0; i < count; i++) rows.push({model: t.getRowNode(top + i), rowIndex: top + i});
    const {cw, ch, dpr} = this.metrics();
    const viewH = sp.screen_.clientHeight;
    // Font size or display scale changed: placements are sized in cells.
    const metricsKey = `${cw}x${ch}@${dpr}`;
    if (this.metricsKey !== metricsKey) {
      this.metricsKey = metricsKey;
      for (const p of this.allPlacements()) this.layoutPlacement(p);
    }

    let origin = null;
    if (rows.length) {
      const rect = sp.rowNodes_.getBoundingClientRect();
      origin = {x: rect.left - screenRect.left, y: rect.top - screenRect.top, row: top};
    }

    this.renderPlaceholders(rows, screenRect, origin);

    const position = (p, depth = 0) => {
      if (p.virtual) return p.placeholderPos || null;
      if (p.parent) {
        if (depth > 8) return null;
        const pp = position(p.parent, depth + 1);
        return pp && {x: pp.x + p.H * cw, y: pp.y + p.V * ch};
      }
      const abs = this.anchorRow(p);
      if (abs == null || !origin) return null;
      return {x: origin.x + p.col * cw, y: origin.y + (abs - origin.row) * ch};
    };

    for (const p of [...this.allPlacements()]) {
      if (p.virtual) continue;
      const pos = position(p);
      if (p.gone && !p.parent) {
        this.dropPlacement(p);
        continue;
      }
      const top = pos && pos.y + p.offY;
      if (!pos || top + p.dh <= 0 || top >= viewH) {
        if (p.el) p.el.style.display = 'none';
        continue;
      }
      if (!p.el) {
        p.el = this.t.document_.createElement('canvas');
        p.el.style.position = 'absolute';
      }
      const layer = p.z < 0 ? this.below : this.above;
      if (p.el.parentNode !== layer) layer.appendChild(p.el);
      const key = `${p.dw}x${p.dh}@${dpr}`;
      if (p.drawn !== key) {
        p.drawn = key;
        drawSlice(p.el, p.image, p.src, 0, 0, p.dw, p.dh, p.dw, p.dh, dpr, null);
      }
      // Stacking: z first, then lower image id below higher.
      Object.assign(p.el.style, {
        display: '', left: `${pos.x + p.offX}px`, top: `${top}px`,
        zIndex: String(Math.max(-2147483647, Math.min(2147483647, p.z))),
      });
    }
  }

  /** Draws images over runs of U+10EEEE placeholder cells. */
  renderPlaceholders(rows, screenRect, origin) {
    const doc = this.t.document_;
    const {cw, ch, dpr} = this.metrics();
    for (const p of this.allPlacements()) if (p.virtual) p.placeholderPos = null;
    let used = 0;
    if (!origin) {
      this.phPool.forEach((el) => { el.style.display = 'none'; });
      return;
    }
    const background = this.t.getPrefs().get('background-color');

    for (const row of rows) {
      const cells = [];
      let colsBefore = 0;
      for (const node of row.model.nodes) {
        const text = node.txt, attrs = node.attrs;
        const fg = attrs.fci >= 0 ? attrs.fci : attrs.fcs;
        const palette = this.t.getPrefs().get('color-palette-overrides') || [];
        const bg = attrs.bcs || (attrs.bci >= 0 && palette[attrs.bci]) || background;
        for (let k = text.indexOf(PLACEHOLDER); k >= 0; k = text.indexOf(PLACEHOLDER, k + 2)) {
          const marks = [];
          for (let j = k + 2; j < text.length && marks.length < 3;) {
            const cp = text.codePointAt(j), index = DIACRITIC_INDEX.get(cp);
            if (index === undefined) break;
            marks.push(index);
            j += cp > 0xffff ? 2 : 1;
          }
          cells.push({col: colsBefore + lib.wc.strWidth(text.slice(0, k)), marks, fg, bg});
        }
        colsBefore += node.wcw;
      }
      const rowRect = {
        left: screenRect.left + origin.x,
        top: screenRect.top + origin.y + (row.rowIndex - origin.row) * ch,
      };

      // Fill in omitted diacritics from the cell to the left (spec rules).
      let prev = null;
      for (const c of cells) {
        const same = prev && prev.fg === c.fg && prev.col === c.col - 1;
        const [r, col, msb] = c.marks;
        if (c.marks.length === 0) {
          Object.assign(c, same ? {prow: prev.prow, pcol: prev.pcol + 1, msb: prev.msb} : {prow: 0, pcol: 0, msb: 0});
        } else if (c.marks.length === 1) {
          Object.assign(c, {prow: r}, same && prev.prow === r ? {pcol: prev.pcol + 1, msb: prev.msb} : {pcol: 0, msb: 0});
        } else if (c.marks.length === 2) {
          c.prow = r; c.pcol = col;
          c.msb = same && prev.prow === r && prev.pcol === col - 1 ? prev.msb : 0;
        } else {
          Object.assign(c, {prow: r, pcol: col, msb});
        }
        c.id = ((colorToId(c.fg) | (c.msb << 24)) >>> 0);
        prev = c;
      }

      // Contiguous cells of the same image row become one canvas.
      for (let i = 0; i < cells.length;) {
        let j = i + 1;
        while (j < cells.length && cells[j].id === cells[i].id && cells[j].prow === cells[i].prow &&
               cells[j].pcol === cells[j - 1].pcol + 1 && cells[j].col === cells[j - 1].col + 1 &&
               cells[j].bg === cells[i].bg) j++;
        const first = cells[i], n = j - i;
        i = j;
        const image = first.id && this.images.get(first.id);
        const vp = image && [...image.placements.values()].find((p) => p.virtual);
        if (!vp) continue;

        // Fit the whole image into the virtual placement's cells, centered.
        const areaW = vp.cols * cw, areaH = vp.rows * ch;
        const scale = Math.min(areaW / vp.src.w, areaH / vp.src.h);
        const fw = vp.src.w * scale, fh = vp.src.h * scale;
        const ox = (areaW - fw) / 2 - first.pcol * cw, oy = (areaH - fh) / 2 - first.prow * ch;

        const el = this.phPool[used] || (this.phPool[used] = doc.createElement('canvas'));
        used++;
        el.style.position = 'absolute';
        if (el.parentNode !== this.above) this.above.appendChild(el);
        const key = [first.id, image.seq, first.prow, first.pcol, n, cw, ch, dpr, first.bg, vp.cols, vp.rows].join('|');
        if (el.dataset.key !== key) {
          el.dataset.key = key;
          drawSlice(el, image, vp.src, ox, oy, fw, fh, n * cw, ch, dpr, first.bg);
        }
        const left = rowRect.left - screenRect.left + first.col * cw;
        const top = rowRect.top - screenRect.top;
        Object.assign(el.style, {display: '', left: `${left}px`, top: `${top}px`, zIndex: String(vp.z)});
        // Where the placeholder image's top-left cell is, for relative placements.
        const x = left - first.pcol * cw, y = top - first.prow * ch;
        vp.placeholderPos = vp.placeholderPos
          ? {x: Math.min(vp.placeholderPos.x, x), y: Math.min(vp.placeholderPos.y, y)} : {x, y};
      }
    }
    for (let k = used; k < this.phPool.length; k++) this.phPool[k].style.display = 'none';
  }
}

BlinkGraphics.QUOTA = 320 * 1024 * 1024;        // decoded RGBA bytes, like kitty
BlinkGraphics.MAX_BASE64 = 400 * 1024 * 1024;   // one transmission
BlinkGraphics.MAX_PIXELS = 100 * 1000 * 1000;

const PLACEHOLDER = '\u{10EEEE}';

// Row/column diacritics, in order (index = value). From kitty's
// gen/rowcolumn-diacritics.txt.
const DIACRITIC_INDEX = new Map([
    0x0305, 0x030d, 0x030e, 0x0310, 0x0312, 0x033d, 0x033e, 0x033f, 0x0346, 0x034a, 0x034b, 0x034c,
    0x0350, 0x0351, 0x0352, 0x0357, 0x035b, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    0x036a, 0x036b, 0x036c, 0x036d, 0x036e, 0x036f, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
    0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059c, 0x059d, 0x059e, 0x059f, 0x05a0, 0x05a1,
    0x05a8, 0x05a9, 0x05ab, 0x05ac, 0x05af, 0x05c4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
    0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065a, 0x065b, 0x065d, 0x065e, 0x06d6, 0x06d7, 0x06d8,
    0x06d9, 0x06da, 0x06db, 0x06dc, 0x06df, 0x06e0, 0x06e1, 0x06e2, 0x06e4, 0x06e7, 0x06e8, 0x06eb,
    0x06ec, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073a, 0x073d, 0x073f, 0x0740, 0x0741, 0x0743,
    0x0745, 0x0747, 0x0749, 0x074a, 0x07eb, 0x07ec, 0x07ed, 0x07ee, 0x07ef, 0x07f0, 0x07f1, 0x07f3,
    0x0816, 0x0817, 0x0818, 0x0819, 0x081b, 0x081c, 0x081d, 0x081e, 0x081f, 0x0820, 0x0821, 0x0822,
    0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082a, 0x082b, 0x082c, 0x082d, 0x0951, 0x0953, 0x0954,
    0x0f82, 0x0f83, 0x0f86, 0x0f87, 0x135d, 0x135e, 0x135f, 0x17dd, 0x193a, 0x1a17, 0x1a75, 0x1a76,
    0x1a77, 0x1a78, 0x1a79, 0x1a7a, 0x1a7b, 0x1a7c, 0x1b6b, 0x1b6d, 0x1b6e, 0x1b6f, 0x1b70, 0x1b71,
    0x1b72, 0x1b73, 0x1cd0, 0x1cd1, 0x1cd2, 0x1cda, 0x1cdb, 0x1ce0, 0x1dc0, 0x1dc1, 0x1dc3, 0x1dc4,
    0x1dc5, 0x1dc6, 0x1dc7, 0x1dc8, 0x1dc9, 0x1dcb, 0x1dcc, 0x1dd1, 0x1dd2, 0x1dd3, 0x1dd4, 0x1dd5,
    0x1dd6, 0x1dd7, 0x1dd8, 0x1dd9, 0x1dda, 0x1ddb, 0x1ddc, 0x1ddd, 0x1dde, 0x1ddf, 0x1de0, 0x1de1,
    0x1de2, 0x1de3, 0x1de4, 0x1de5, 0x1de6, 0x1dfe, 0x20d0, 0x20d1, 0x20d4, 0x20d5, 0x20d6, 0x20d7,
    0x20db, 0x20dc, 0x20e1, 0x20e7, 0x20e9, 0x20f0, 0x2cef, 0x2cf0, 0x2cf1, 0x2de0, 0x2de1, 0x2de2,
    0x2de3, 0x2de4, 0x2de5, 0x2de6, 0x2de7, 0x2de8, 0x2de9, 0x2dea, 0x2deb, 0x2dec, 0x2ded, 0x2dee,
    0x2def, 0x2df0, 0x2df1, 0x2df2, 0x2df3, 0x2df4, 0x2df5, 0x2df6, 0x2df7, 0x2df8, 0x2df9, 0x2dfa,
    0x2dfb, 0x2dfc, 0x2dfd, 0x2dfe, 0x2dff, 0xa66f, 0xa67c, 0xa67d, 0xa6f0, 0xa6f1, 0xa8e0, 0xa8e1,
    0xa8e2, 0xa8e3, 0xa8e4, 0xa8e5, 0xa8e6, 0xa8e7, 0xa8e8, 0xa8e9, 0xa8ea, 0xa8eb, 0xa8ec, 0xa8ed,
    0xa8ee, 0xa8ef, 0xa8f0, 0xa8f1, 0xaab0, 0xaab2, 0xaab3, 0xaab7, 0xaab8, 0xaabe, 0xaabf, 0xaac1,
    0xfe20, 0xfe21, 0xfe22, 0xfe23, 0xfe24, 0xfe25, 0xfe26, 0x10a0f, 0x10a38, 0x1d185, 0x1d186, 0x1d187,
    0x1d188, 0x1d189, 0x1d1aa, 0x1d1ab, 0x1d1ac, 0x1d1ad, 0x1d242, 0x1d243, 0x1d244,
].map((cp, i) => [cp, i]));

class GraphicsError extends Error {
  constructor(code, message) {
    super(`${code}:${message}`);
  }
}

/** `a=T,f=100,i=7` -> {a: 'T', f: 100, i: 7}. */
function parseKeys(control) {
  const keys = {};
  for (const kv of control.split(',')) {
    const eq = kv.indexOf('=');
    if (eq < 1) continue;
    const k = kv.slice(0, eq), v = kv.slice(eq + 1);
    keys[k] = k.length === 1 && 'atod'.includes(k) ? v : Number(v) || 0;
  }
  return keys;
}

function base64Bytes(s) {
  let bin;
  try {
    bin = atob(s.replace(/\s/g, ''));
  } catch (e) {
    throw new GraphicsError('EINVAL', 'Invalid base64 data');
  }
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function inflate(bytes) {
  try {
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  } catch (e) {
    throw new GraphicsError('EINVAL', 'Failed to decompress image data');
  }
}

/** PNG (f=100) or raw RGB/RGBA (f=24/32) -> {bitmap, width, height, bytes}. */
async function decodeImage(keys, bytes) {
  const format = keys.f || 32;
  let bitmap;
  if (format === 100) {
    try {
      bitmap = await createImageBitmap(new Blob([bytes], {type: 'image/png'}));
    } catch (e) {
      throw new GraphicsError('EBADPNG', 'Failed to decode PNG data');
    }
  } else if (format === 24 || format === 32) {
    const w = keys.s, h = keys.v;
    if (!w || !h) throw new GraphicsError('EINVAL', 'Width and height (s, v) are required');
    if (w * h > BlinkGraphics.MAX_PIXELS) throw new GraphicsError('EFBIG', 'Image is too large');
    const bpp = format / 8, need = w * h * bpp;
    if (bytes.length < need) {
      throw new GraphicsError('ENODATA', `Insufficient image data: ${bytes.length} < ${need}`);
    }
    let rgba;
    if (bpp === 4) {
      rgba = new Uint8ClampedArray(bytes.buffer, bytes.byteOffset, need);
    } else {
      rgba = new Uint8ClampedArray(w * h * 4);
      for (let i = 0, j = 0; i < need; i += 3, j += 4) {
        rgba[j] = bytes[i]; rgba[j + 1] = bytes[i + 1]; rgba[j + 2] = bytes[i + 2]; rgba[j + 3] = 255;
      }
    }
    bitmap = await createImageBitmap(new ImageData(rgba, w, h));
  } else {
    throw new GraphicsError('EINVAL', `Unknown image format: ${format}`);
  }
  if (bitmap.width * bitmap.height > BlinkGraphics.MAX_PIXELS) {
    bitmap.close();
    throw new GraphicsError('EFBIG', 'Image is too large');
  }
  return {bitmap, width: bitmap.width, height: bitmap.height, bytes: bitmap.width * bitmap.height * 4};
}

/** The x/y/w/h source rectangle, clipped to the image. */
function sourceRect(keys, image) {
  const x = Math.min(keys.x || 0, image.width - 1), y = Math.min(keys.y || 0, image.height - 1);
  const w = Math.max(1, Math.min(keys.w || image.width - x, image.width - x));
  const h = Math.max(1, Math.min(keys.h || image.height - y, image.height - y));
  return {x, y, w, h};
}

/**
 * Draws `src` of `image` scaled to fw×fh at (ox, oy) on a canvas of
 * width×height CSS pixels, over an optional background color.
 */
function drawSlice(canvas, image, src, ox, oy, fw, fh, width, height, dpr, background) {
  canvas.width = Math.max(1, Math.round(width * dpr));
  canvas.height = Math.max(1, Math.round(height * dpr));
  canvas.style.width = `${width}px`;
  canvas.style.height = `${height}px`;
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingQuality = 'high';
  if (background) {
    ctx.fillStyle = background;
    ctx.fillRect(0, 0, canvas.width, canvas.height);
  }
  ctx.drawImage(image.bitmap, src.x, src.y, src.w, src.h, ox * dpr, oy * dpr, fw * dpr, fh * dpr);
}

/** Image id from a placeholder's foreground: 256-color index or 24-bit RGB. */
function colorToId(fg) {
  if (typeof fg === 'number') return fg;
  const m = typeof fg === 'string' && fg.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/); // hterm writes "rgb(1 ,2 ,3)"
  return m ? (m[1] << 16) | (m[2] << 8) | Number(m[3]) : 0;
}

// Keep placeholders one cell wide even when the selected font lacks their
// glyph. Blink row models already preserve source foreground colors.
(() => {
  const split = hterm.TextAttributes.splitWidecharString;
  hterm.TextAttributes.splitWidecharString = function(str) {
    const tokens = split.apply(this, arguments);
    if (str.indexOf(PLACEHOLDER) < 0) return tokens;
    const out = [];
    const plain = (text) => ({
      str: text, asciiNode: !/[^\x00-\x7f]/.test(text), wcStrWidth: lib.wc.strWidth(text),
    });
    for (const token of tokens) {
      if (token.wcNode || token.str.indexOf(PLACEHOLDER) < 0) {
        out.push(token);
        continue;
      }
      let rest = token.str;
      for (let i; (i = rest.indexOf(PLACEHOLDER)) >= 0;) {
        if (i > 0) out.push(plain(rest.slice(0, i)));
        let j = i + PLACEHOLDER.length; // take the zero-width marks along
        while (j < rest.length && lib.wc.charWidth(rest.codePointAt(j)) === 0) {
          j += rest.codePointAt(j) > 0xffff ? 2 : 1;
        }
        out.push({str: rest.slice(i, j), wcNode: true, asciiNode: false, wcStrWidth: 1});
        rest = rest.slice(j);
      }
      if (rest) out.push(plain(rest));
    }
    return out;
  };


})();

window.BlinkGraphics = BlinkGraphics;
})();
