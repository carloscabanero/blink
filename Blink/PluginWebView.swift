import SwiftUI
import WebKit

private final class PluginAssets: NSObject, WKURLSchemeHandler {
  let package: PluginPackage
  init(package: PluginPackage) { self.package = package }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    do {
      guard let url = task.request.url, url.host == package.manifest.id, task.request.httpMethod == "GET" else {
        throw PluginPackage.Failure.invalid("Invalid resource request")
      }
      let path = String(url.path.dropFirst())
      let file = try package.asset(path)
      let attributes = try file.resourceValues(forKeys: [.fileSizeKey])
      guard (attributes.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw PluginPackage.Failure.invalid("Asset exceeds 8 MiB") }
      let data = try Data(contentsOf: file)
      let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json",
                   "png": "image/png", "jpg": "image/jpeg", "svg": "image/svg+xml", "woff2": "font/woff2"]
      let csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
        "Content-Type": types[file.pathExtension] ?? "application/octet-stream",
        "Content-Security-Policy": csp, "X-Content-Type-Options": "nosniff"
      ])!
      task.didReceive(response); task.didReceive(data); task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// A plugin's web view, as a UIKit controller so it can fill a Blink tab.
@MainActor final class PluginWebController: UIViewController {
  let package: PluginPackage
  private let coordinator: PluginWebView.Bridge
  private(set) var webView: WKWebView!

  /// `launch` is reported by host.info(): how the app was opened (command, args).
  init(package: PluginPackage, launch: [String: Any]? = nil) {
    self.package = package
    coordinator = PluginWebView.Bridge(package: package, launch: launch)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(PluginAssets(package: package), forURLScheme: "blink-plugin")
    let content = config.userContentController
    content.addScriptMessageHandler(coordinator, contentWorld: .page, name: "blink")
    content.addUserScript(WKUserScript(source: PluginWebView.sdk, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = coordinator
    webView.isOpaque = false
    coordinator.webView = webView
    var url = URLComponents()
    url.scheme = "blink-plugin"
    url.host = package.manifest.id
    url.path = "/" + package.manifest.entry
    if let entry = url.url { webView.load(URLRequest(url: entry)) }
    self.webView = webView
    view = webView
  }

  /// Stops the app: its database sessions, tunnels and script bridge.
  func shutdown() {
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "blink", contentWorld: .page)
    webView?.navigationDelegate = nil
    webView?.stopLoading()
    coordinator.database?.close()
  }

  deinit {
    let coordinator = coordinator
    Task { @MainActor in coordinator.database?.close() }
  }
}

struct PluginWebView: UIViewControllerRepresentable {
  let package: PluginPackage

  func makeUIViewController(context: Context) -> PluginWebController { PluginWebController(package: package) }
  func updateUIViewController(_ controller: PluginWebController, context: Context) {}
  static func dismantleUIViewController(_ controller: PluginWebController, coordinator: ()) { controller.shutdown() }

  final class Bridge: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private let package: PluginPackage
    private let launch: [String: Any]?
    weak var webView: WKWebView?
    @MainActor var database: PluginDatabase?

    var spotifyAllowed: Bool {
      guard package.manifest.id == "org.blink.spotify", package.manifest.permissions.contains("spotify"),
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("Plugins/org.blink.spotify") else { return false }
      return package.root == bundled.resolvingSymlinksInPath().standardizedFileURL
    }

    init(package: PluginPackage, launch: [String: Any]? = nil) {
      self.package = package
      self.launch = launch
    }

    private func isOwnOrigin(_ url: URL?) -> Bool {
      url?.scheme == "blink-plugin" && url?.host == package.manifest.id
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if spotifyAllowed, action.sourceFrame.isMainFrame, isOwnOrigin(action.sourceFrame.request.url),
         action.navigationType == .linkActivated, let url = action.request.url,
         url.scheme == "https", url.host == "open.spotify.com", url.user == nil, url.password == nil, url.port == nil {
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
        return
      }
      decisionHandler(action.targetFrame?.isMainFrame == true && isOwnOrigin(action.request.url) ? .allow : .cancel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
      guard message.frameInfo.isMainFrame, isOwnOrigin(message.frameInfo.request.url),
            let request = message.body as? [String: Any], let method = request["method"] as? String else {
        replyHandler(nil, "Invalid request")
        return
      }

      if method.hasPrefix("spotify.") {
        guard spotifyAllowed else { replyHandler(nil, "Spotify requires the bundled app"); return }
        var presenter = webView?.window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        Task { @MainActor in
          do { replyHandler(try await SpotifyService.shared.call(method, request, presentingFrom: presenter), nil) }
          catch { replyHandler(nil, error.localizedDescription) }
        }
        return
      }

      let manifest = package.manifest
      let hasStorage = manifest.permissions.contains("storage")
      let hasDatabase = manifest.permissions.contains("database")
      if method == "host.info" {
        var info: [String: Any] = ["apiVersion": 1, "host": "blink", "platform": "ios", "pluginID": manifest.id,
                                   "capabilities": ["host.info"] + (spotifyAllowed ? ["spotify"] : []) + (hasDatabase ? ["database"] : []) + (hasStorage ? ["storage.get", "storage.set"] : [])]
        if let launch { info["launch"] = launch }
        replyHandler(info, nil)
        return
      }

      if method.hasPrefix("database.") {
        guard hasDatabase else { replyHandler(nil, "App has not declared the database permission"); return }
        Task { @MainActor in
          if self.database == nil { self.database = PluginDatabase(manifest: manifest, webView: self.webView) }
          do { replyHandler(try await self.database!.call(method, request), nil) }
          catch { replyHandler(nil, error.localizedDescription) }
        }
        return
      }

      guard hasStorage, let key = request["key"] as? String, !key.isEmpty, key.utf8.count <= 256 else {
        replyHandler(nil, "Permission denied or invalid key")
        return
      }
      let namespace = "plugin.v1." + manifest.id
      var values = UserDefaults.standard.dictionary(forKey: namespace) as? [String: String] ?? [:]
      switch method {
      case "storage.get":
        replyHandler(values[key] ?? NSNull(), nil)
      case "storage.set":
        guard let value = request["value"] as? String else { replyHandler(nil, "Value must be a string"); return }
        values[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: values), data.count <= 65536 else {
          replyHandler(nil, "Storage quota exceeded (64 KiB)")
          return
        }
        UserDefaults.standard.set(values, forKey: namespace)
        replyHandler(true, nil)
      default:
        replyHandler(nil, "Unsupported method")
      }
    }
  }

  static let sdk = """
  (() => {
    const call = (method, args = {}) => window.webkit.messageHandlers.blink.postMessage({method, ...args});
    Object.defineProperty(window, 'blink', {value: Object.freeze({
      apiVersion: 1,
      host: Object.freeze({info: () => call('host.info')}),
      spotify: Object.freeze({
        status: () => call('spotify.status'), login: clientID => call('spotify.login', {clientID}), logout: () => call('spotify.logout'),
        request: (verb, path, query, body) => call('spotify.request', {verb, path, query, ...(body === undefined ? {} : {body})}),
        artwork: url => call('spotify.artwork', {url})
      }),
      database: Object.freeze({connect: () => call('database.connect'),
        connections: () => call('database.connections'), sshHosts: () => call('database.sshHosts'),
        edit: id => call('database.edit', id ? {id} : {}), importURL: () => call('database.importURL'),
        duplicate: id => call('database.duplicate', {id}), remove: id => call('database.remove', {id}),
        copyURL: id => call('database.copyURL', {id}), open: id => call('database.open', {id}),
        status: () => call('database.status'), disconnect: () => call('database.disconnect'),
        query: (sql, options = {}) => call('database.query', {...options, sql}),
        execute: statements => call('database.execute', {statements}),
        cancel: () => call('database.cancel')}),
      storage: Object.freeze({get: key => call('storage.get', {key}), set: (key, value) => call('storage.set', {key, value})})
    }), writable: false, configurable: false});
  })();
  """
}
