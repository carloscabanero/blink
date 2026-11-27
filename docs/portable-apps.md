# Portable apps (experimental)

Press **⌘⇧A** on a hardware keyboard or pick **Shell → Show Apps**.
You can also open Blink Settings (for example, run `config` at the Blink prompt), then
choose **Apps (Experimental)** under **Configuration**. Tap **Plugin
Playground** to try a bundled app, or choose **Install from GitHub…** and
paste a public repository or plugin-folder URL. For a terminal UI, try:

```text
https://github.com/myneid/wink/tree/main/examples/hterm-tui
```

Apps open full screen in a new Blink tab (close the tab to quit). Tap one in
Apps, type `apps open <name>`, or use a command the app declares, such as
`dbw` for the Database Workbench (`dbw <connection>` connects right away).
`apps` lists installed apps and their commands. App commands never replace a
Blink command or another app's command.

**Available** lists apps you can install, such as the Database Workbench.
Spotify Connect is available through the bundled Spotify app. Its native bridge is not exposed to GitHub-installed apps.

Review the app name, ID, version, permissions, commands and pinned GitHub
commit before installation. Long-press an installed app to open its source repository or
check for updates. Updates require another review and preserve the previous
package and the app's stored data.

Blink and Wink use the same version-1 manifest and HTML entry point.
Blink provides `blink.host.info()` and, when requested by the manifest,
`blink.storage.get(key)` and `blink.storage.set(key, value)`. Storage is
limited to 64 KiB per app.

Apps with the `database` permission get `blink.database`, the same API as in
Wink (see the authoring guide): saved MySQL/MariaDB connections edited in
native forms, passwords in the Keychain, and tunnels through your Blink hosts
with Blink's SSH client and keys. Try it with the Database Workbench:

```text
https://github.com/myneid/wink-database
```

`Blink/Database/*.swift` are shared verbatim with Wink; update them from a
Wink checkout with `tools/sync-blink-database.sh`. Consult the
[plugin authoring guide](https://github.com/myneid/wink/blob/main/docs/plugins.md)
for package structure and the hterm starter.

Apps run in separate nonpersistent WebViews with same-package assets and no
general network API, shell, PTY, or access to terminal sessions. Installed
apps can use the database capability for connections the person sets up. The
starter bundles its own hterm; opening it does not replace Blink's terminal.
