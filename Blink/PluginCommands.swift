import Foundation
import ObjectiveC
import UIKit

import ios_system

// Apps open full screen in a Blink tab, from the Apps screen, `apps open`,
// or commands an app declares in its manifest ("commands": ["dbw"]). An app
// can't take a name Blink already has or another app claimed first.

enum PluginLibrary {
  static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("PortableApps", isDirectory: true)
  static let installed = root.appendingPathComponent("Plugins", isDirectory: true)
  static let bundled = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true)

  static func load(from folder: URL?) -> [PluginPackage] {
    guard let folder, let entries = try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries.compactMap { try? PluginPackage(root: $0) }
      .sorted { $0.manifest.id < $1.manifest.id }
  }

  /// Bundled apps, then installed ones; the first of an ID wins.
  static func all() -> [PluginPackage] {
    var ids = Set<String>()
    return (load(from: bundled) + load(from: installed)).filter { ids.insert($0.manifest.id).inserted }
  }

  /// By ID, name or command, ignoring case.
  static func find(_ query: String) -> PluginPackage? {
    let q = query.lowercased()
    let apps = all()
    return apps.first { $0.manifest.id.lowercased() == q }
      ?? apps.first { $0.manifest.name.lowercased() == q }
      ?? PluginCommands.shared.owner(of: q).flatMap { id in apps.first { $0.manifest.id == id } }
  }
}

final class PluginCommands {
  static let shared = PluginCommands()

  private let lock = NSLock()
  /// Commands Blink had before any app added its own.
  private var builtins: Set<String> = []
  /// Command → app ID.
  private var owners: [String: String] = [:]
  private var registered: Set<String> = []

  func owner(of command: String) -> String? { lock.withLock { owners[command] } }

  func commands(of id: String) -> [String] {
    lock.withLock { owners.filter { $0.value == id }.map(\.key).sorted() }
  }

  /// Why each of the package's commands can't be used (empty when all can).
  func conflicts(for package: PluginPackage) -> [String] {
    let apps = PluginLibrary.all()
    return lock.withLock {
      (package.manifest.commands ?? []).compactMap { name in
        if builtins.contains(name) { return "“\(name)” is a Blink command." }
        if let other = owners[name], other != package.manifest.id {
          let otherName = apps.first { $0.manifest.id == other }?.manifest.name ?? other
          return "“\(name)” is already used by \(otherName)."
        }
        return nil
      }
    }
  }

  /// Re-reads installed apps and registers any new commands with the shell.
  /// Call after Blink registers its own commands, and after installs.
  func refresh() {
    lock.lock()
    if builtins.isEmpty {
      // Only once the shell has registered Blink's commands.
      let current = Set((commandsAsArray() as? [String]) ?? [])
      guard current.contains("ssh") else { lock.unlock(); return }
      builtins = current.union(["apps"])
    }
    var next: [String: String] = [:]
    for package in PluginLibrary.all() {
      for name in package.manifest.commands ?? [] where !builtins.contains(name) && next[name] == nil {
        next[name] = package.manifest.id
      }
    }
    owners = next
    let fresh = Set(next.keys).subtracting(registered)
    registered.formUnion(fresh)
    lock.unlock()
    guard !fresh.isEmpty else { return }
    // ios_system takes commands from a plist: name → [framework, function, options, type].
    var list: [String: [String]] = [:]
    for name in fresh { list[name] = ["MAIN", "blinkapp_main", "", "no"] }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("blink-app-commands-\(UUID().uuidString).plist")
    guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0),
          (try? data.write(to: url)) != nil else { return }
    addCommandList(url.path)
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Opening

  /// Opens the app in a new tab of the session's window (or in the session's
  /// own tab with `here`). Runs on the command's thread.
  static func open(_ package: PluginPackage, command: String, args: [String], here: Bool) -> Int32 {
    let session = Unmanaged<MCPSession>.fromOpaque(thread_context).takeUnretainedValue()
    let launch: [String: Any] = ["command": command, "args": args]
    DispatchQueue.main.async {
      guard let view = session.device?.view else { return }
      if here, let term = view.termController as? TermController {
        term.presentPluginApp(package, launch: launch)
      } else if let space = view.window?.rootViewController as? SpaceController {
        space.openPluginApp(package.manifest.id, args: args, command: command)
      }
    }
    if !here { fputs("Opening \(package.manifest.name) in a new tab.\n", thread_stdout) }
    return 0
  }

  /// Quotes an argument for Blink's shell.
  static func quote(_ arg: String) -> String {
    if !arg.isEmpty, arg.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:@=,+".contains($0) }) { return arg }
    if !arg.contains("'") { return "'" + arg + "'" }
    return "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  /// The active window's SpaceController, for opening apps from Settings.
  @MainActor static var activeSpace: SpaceController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
    return (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController as? SpaceController
  }
}

private func printUsage() {
  fputs("""
    Usage: apps                       List installed apps and their commands
           apps open <app> [args…]    Open an app in a new tab (by ID, name or command)

    """, thread_stdout)
}

@_cdecl("apps_main")
public func apps_main(argc: Int32, argv: Argv) -> Int32 {
  var args = Array(argv.args(count: argc).dropFirst())
  guard let verb = args.first else {
    let apps = PluginLibrary.all()
    if apps.isEmpty { fputs("No apps installed. Add some in Settings › Apps.\n", thread_stdout) }
    for package in apps {
      let commands = PluginCommands.shared.commands(of: package.manifest.id)
      let suffix = commands.isEmpty ? "apps open \(PluginCommands.quote(package.manifest.id))" : commands.joined(separator: ", ")
      fputs("\(package.manifest.name)  (\(package.manifest.version))  —  \(suffix)\n", thread_stdout)
    }
    return 0
  }
  args.removeFirst()
  switch verb {
  case "open":
    var here = false
    if args.first == "--here" { here = true; args.removeFirst() }
    guard let query = args.first else { printUsage(); return 1 }
    guard let package = PluginLibrary.find(query) else {
      fputs("apps: no app called “\(query)”. Run apps to list them.\n", thread_stderr)
      return 1
    }
    return PluginCommands.open(package, command: "apps", args: Array(args.dropFirst()), here: here)
  case "-h", "--help", "help":
    printUsage()
    return 0
  default:
    printUsage()
    return 1
  }
}

/// Entry point for every command an app declares.
@_cdecl("blinkapp_main")
public func blinkapp_main(argc: Int32, argv: Argv) -> Int32 {
  let args = argv.args(count: argc)
  let name = URL(fileURLWithPath: args.first ?? "").lastPathComponent
  guard let id = PluginCommands.shared.owner(of: name),
        let package = PluginLibrary.all().first(where: { $0.manifest.id == id }) else {
    fputs("\(name): the app that provided this command isn't installed anymore.\n", thread_stderr)
    return 1
  }
  return PluginCommands.open(package, command: name, args: Array(args.dropFirst()), here: false)
}

// MARK: - Apps in tabs

private var pluginOverlayKey: UInt8 = 0

extension TermController {
  /// Fills this tab with the app. The shell stays underneath; closing the
  /// tab closes the app.
  @MainActor func presentPluginApp(_ package: PluginPackage, launch: [String: Any]) {
    (objc_getAssociatedObject(self, &pluginOverlayKey) as? PluginWebController).map { old in
      old.shutdown()
      old.view.removeFromSuperview()
    }
    let controller = PluginWebController(package: package, launch: launch)
    objc_setAssociatedObject(self, &pluginOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    let app = controller.view!
    let terminal = termView.webView!
    app.translatesAutoresizingMaskIntoConstraints = false
    termView.addSubview(app)
    NSLayoutConstraint.activate([
      app.topAnchor.constraint(equalTo: terminal.topAnchor),
      app.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
      app.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
      app.bottomAnchor.constraint(equalTo: terminal.bottomAnchor),
    ])
    // Keep the terminal from taking the keyboard back on taps and tab switches.
    shouldBlockFirstResponder = true
    _ = terminal.resignFirstResponder()
    title = package.manifest.name
    // The shell may still be finishing its prompt; take focus once it settles.
    // The keyboard comes back when a text field in the app is tapped.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak terminal, weak app] in
      _ = terminal?.resignFirstResponder()
      _ = app?.becomeFirstResponder()
    }
  }
}
