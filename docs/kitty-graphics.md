# Kitty graphics in Blink

Ports Wink commit `34ac039aeb73f5e9871d118a8644a825c6e757de`
(`myneid/wink`, GPL-3.0) to Carlos's `bell-client-v8`, separately from Bell Relay.

## Scope

Direct/streamed PNG, RGB and RGBA uploads; chunking; queries/replies; stored
images; placements/cropping/scaling/deletion; relative placements; Unicode
placeholder virtual placements (including tmux-style RGB image IDs); scrollback,
native scrolling, alternate screens and resize; CSI 14/16/18 size reports.

Animation is unsupported. Local-file, temporary-file and shared-memory transfers
are deliberately unavailable: terminal output cannot read/delete files in Blink's
sandbox. Use inline transfers over SSH. Compressed data requires the browser's
`DecompressionStream` support.

## Blink adaptation

The adapter reads Blink's React row models, not DOM row nodes, retaining row
identity for anchors and source foreground colors for placeholders. Drawing
uses native-scroller viewport geometry. The minified hterm bundle is unchanged.
Only APC and relevant size-query dispatch entries are intercepted; all other
sequences retain their existing handlers. Decodes preserve subsequent output
order, including native base64 writes. Native theme background readback remains
intact. Both scripts are registered as Xcode resources.

## Manual device checks

Build Blink normally. On the machine connected to Blink (local or SSH), run:

```sh
python3 Tools/KittyGraphics/blink-icat --cols 20 image.png
```

PNG needs only Python 3; conversion from other formats uses macOS `sips`.
The helper streams bytes instead of asking the terminal to open a path.
For tmux, set these before running the same helper inside a pane:

```tmux
set -g allow-passthrough on
set -as terminal-features ',xterm*:RGB'
```

Check text after images, scrolling away/back, alternate-screen applications,
pane/font resizing and clearing. Placeholder cells should stay aligned and not
show fallback glyphs.

## Automated checks

With Puppeteer installed separately (not an application dependency):

```sh
NODE_PATH=/path/to/node_modules CHROME_PATH=/path/to/chrome \
  node Tools/KittyGraphics/test.cjs
```

The local-only suite loads Blink's actual hterm bundle plus actual app
`term.html`/`term.js` startup. It verifies canvas pixels, async ordering, native
bridges, theme readback, scrolling, alternate screens, placeholders, resize,
PNG chunks, acknowledgments and deletion. Optional:
`KITTY_SCREENSHOT=/tmp/blink-kitty.png` saves the app-rendering preview.

Physical iPhone/iPad and live SSH/tmux checks remain manual: Chromium is not
proof of WKWebView/device behavior. No signed iOS build or device installation
was performed for this resource-only change.
