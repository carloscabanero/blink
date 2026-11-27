import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

import BlinkConfig
import SSH

// Blink's side of the portable `database` capability: dialogs and SSH tunnels.
// The API, the MySQL client and saved connections are the platform-neutral
// Database/*.swift files, shared verbatim with Wink.

@MainActor final class PluginDatabase: DatabaseHostUI {
  private weak var webView: WKWebView?
  private var bridge: DatabaseBridge!

  static var storeURL: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("PortableApps/databases.json")
  }

  init(manifest: PluginManifest, webView: WKWebView?) {
    self.webView = webView
    let environment = DatabaseHostEnvironment(
      storeURL: Self.storeURL, keychainService: "Blink Database", sshHosts: Self.sshHosts,
      openTunnel: { destination in try await BlinkSSHTunnel.open(destination) })
    bridge = DatabaseBridge(appName: manifest.name, owner: manifest.id, environment: environment, ui: self)
  }

  func attach(_ webView: WKWebView) { self.webView = webView }

  func call(_ method: String, _ args: [String: Any]) async throws -> Any { try await bridge.call(method, args) }

  func close() { bridge.close() }

  static func sshHosts() -> [DatabaseSSHHost] {
    (BKHosts.allHosts() ?? []).compactMap { h in
      guard let alias = h.host, !alias.isEmpty else { return nil }
      return DatabaseSSHHost(alias: alias, hostName: h.hostName, user: h.user, port: h.port?.intValue)
    }
  }

  // MARK: - Presenting

  private var presenter: UIViewController? {
    var top = webView?.window?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }

  private func present(_ controller: UIViewController) {
    if let popover = controller.popoverPresentationController, let view = webView {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    presenter?.present(controller, animated: true)
  }

  // MARK: - DatabaseHostUI

  func editConnection(_ draft: DatabaseConnection, password: String?, hasSavedPassword: Bool, title: String,
                      problem: String?, sshHosts: [DatabaseSSHHost]) async -> (connection: DatabaseConnection, password: String)? {
    guard presenter != nil else { return nil }
    return await withCheckedContinuation { continuation in
      var finished = false
      var host: UIHostingController<AnyView>?
      let finish: ((connection: DatabaseConnection, password: String)?) -> Void = { result in
        guard !finished else { return }
        finished = true
        host?.dismiss(animated: true)
        continuation.resume(returning: result)
      }
      let form = DatabaseConnectionForm(draft: draft, password: password ?? "", hasSavedPassword: hasSavedPassword,
                                        title: title, problem: problem, sshHosts: sshHosts, finish: finish)
      host = UIHostingController(rootView: AnyView(NavigationView { form }.navigationViewStyle(.stack)))
      host?.isModalInPresentation = true
      present(host!)
    }
  }

  func askForURL(prefill: String, problem: String?) async -> String? {
    guard presenter != nil else { return nil }
    return await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: "Import Connection from URL",
        message: problem ?? "Paste a MySQL or MariaDB URL, for example mysql://user:password@host:3306/database. TablePlus mysql+ssh:// URLs work too. Add ?ssh=alias to go through one of your Blink hosts.",
        preferredStyle: .alert)
      alert.addTextField { field in
        field.text = prefill
        field.placeholder = "mysql://user:password@host:3306/database"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .URL
      }
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) })
      alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in continuation.resume(returning: alert.textFields?.first?.text ?? "") })
      present(alert)
    }
  }

  func confirmRemove(_ connection: DatabaseConnection) async -> Bool {
    guard presenter != nil else { return false }
    return await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: "Delete “\(connection.title)”?",
        message: "The connection and its saved password are removed from Blink. The database itself is not touched.", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
      alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in continuation.resume(returning: true) })
      present(alert)
    }
  }

  func askIncludePassword(_ connection: DatabaseConnection) async -> Bool? {
    guard presenter != nil else { return nil }
    return await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: "Copy URL for “\(connection.title)”",
        message: "Anyone you share a URL with a password can sign in as \(connection.user).", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Copy Without Password", style: .default) { _ in continuation.resume(returning: false) })
      alert.addAction(UIAlertAction(title: "Copy With Password", style: .default) { _ in continuation.resume(returning: true) })
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) })
      present(alert)
    }
  }

  func setClipboard(_ text: String) { UIPasteboard.general.string = text }

  /// Reading the pasteboard makes iOS ask for permission, so the URL field
  /// starts empty; people paste into it with the system Paste menu instead.
  func clipboard() -> String? { nil }
}

// MARK: - Connection form

private struct DatabaseConnectionForm: View {
  let title: String
  let problem: String?
  let sshHosts: [DatabaseSSHHost]
  let hasSavedPassword: Bool
  let finish: ((connection: DatabaseConnection, password: String)?) -> Void

  @State private var draft: DatabaseConnection
  @State private var password: String
  @State private var port: String
  @State private var url = ""
  @State private var urlNote = ""

  init(draft: DatabaseConnection, password: String, hasSavedPassword: Bool, title: String, problem: String?,
       sshHosts: [DatabaseSSHHost], finish: @escaping ((connection: DatabaseConnection, password: String)?) -> Void) {
    self.title = title
    self.problem = problem
    self.sshHosts = sshHosts
    self.hasSavedPassword = hasSavedPassword
    self.finish = finish
    _draft = State(initialValue: draft)
    _password = State(initialValue: password)
    _port = State(initialValue: String(draft.port))
  }

  private static let environmentNames = ["None", "Local", "Development", "Testing", "Staging", "Production"]

  var body: some View {
    Form {
      if let problem {
        Section { Text(problem).foregroundColor(.red) }
      }
      Section(footer: Text(urlNote)) {
        TextField("Paste mysql://user:password@host/db to fill in", text: $url)
          .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
          .onChange(of: url) { fill(from: $0) }
      }
      Section(header: Text("Connection")) {
        row("Name") { TextField("Optional", text: $draft.name) }
        Picker("Environment", selection: $draft.environment) {
          ForEach(Array(DatabaseConnection.environments.enumerated()), id: \.offset) { index, value in
            Text(Self.environmentNames[index]).tag(value)
          }
        }
        row("Host") { TextField("127.0.0.1", text: $draft.host).keyboardType(.URL) }
        row("Port") { TextField("3306", text: $port).keyboardType(.numberPad) }
        row("User") { TextField("Required", text: $draft.user) }
        row("Password") { SecureField(hasSavedPassword ? "Saved — leave blank to keep" : "None", text: $password) }
        row("Database") { TextField("Optional", text: $draft.database) }
      }
      Section(header: Text("Over SSH"), footer: Text("With SSH, Host is as seen from the SSH server, usually 127.0.0.1. Tunnels use your Blink keys.")) {
        HStack {
          TextField("None — connect directly", text: $draft.ssh).textInputAutocapitalization(.never).autocorrectionDisabled()
          Menu {
            Button("None") { draft.ssh = "" }
            ForEach(sshHosts, id: \.alias) { host in Button(host.alias) { draft.ssh = host.alias } }
          } label: { Image(systemName: "chevron.up.chevron.down") }
        }
      }
      Section {
        Toggle("Read-only", isOn: $draft.readOnly)
        Toggle("Require SSL/TLS", isOn: $draft.ssl)
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(nil) } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          var c = draft
          c.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 0
          c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
          c.host = c.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : c.host.trimmingCharacters(in: .whitespacesAndNewlines)
          c.user = c.user.trimmingCharacters(in: .whitespacesAndNewlines)
          c.database = c.database.trimmingCharacters(in: .whitespacesAndNewlines)
          c.ssh = c.ssh.trimmingCharacters(in: .whitespacesAndNewlines)
          finish((c, password))
        }
      }
    }
  }

  private func row<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
    LabeledContent(label) {
      field()
        .multilineTextAlignment(.trailing)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private func fill(from text: String) {
    guard !text.isEmpty else { urlNote = ""; return }
    do {
      let parsed = try DatabaseURL.parse(text, sshHosts: sshHosts)
      var c = parsed.connection
      c.id = draft.id
      if c.name.isEmpty { c.name = draft.name }
      draft = c
      port = String(c.port)
      if let p = parsed.password { password = p }
      urlNote = "Filled in from the URL" + (c.ssh.isEmpty ? "." : " (SSH via \(c.ssh)).")
    } catch {
      urlNote = error.localizedDescription
    }
  }
}

// MARK: - SSH tunnel

/// An SSH connection made with Blink's own client, keys and hosts. Each
/// stream is a direct-tcpip channel bridged to a socketpair, so the MySQL
/// client can use it like a socket from its own thread.
final class BlinkSSHTunnel: DatabaseTunnel, @unchecked Sendable {
  private let lock = NSLock()
  private var client: SSHClient?
  private var runLoop: RunLoop?
  private var cancellables: [AnyCancellable] = []    // touched on the SSH thread
  private var streams: [SSH.Stream] = []             // touched on the SSH thread
  private var alive = false

  var isAlive: Bool { lock.withLock { alive && client != nil } }

  static func open(_ destination: String) async throws -> BlinkSSHTunnel {
    let (hostName, config) = try clientConfig(for: destination)
    let tunnel = BlinkSSHTunnel()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      var resumed = false
      let resume: (Error?) -> Void = { error in
        guard !resumed else { return }
        resumed = true
        if let error { continuation.resume(throwing: DatabaseFailure("SSH to \(destination) failed: \(error.localizedDescription)")) }
        else { continuation.resume() }
      }
      let thread = Thread {
        tunnel.runLoop = RunLoop.current
        let dial = SSHClient.dial(hostName, with: config)
          .sink(receiveCompletion: { completion in
            if case .failure(let error) = completion { resume(error) }
          }, receiveValue: { client in
            client.handleSessionException = { _ in tunnel.lock.withLock { tunnel.alive = false } }
            tunnel.lock.withLock { tunnel.client = client; tunnel.alive = true }
            resume(nil)
          })
        tunnel.cancellables.append(dial)
        SSHClient.run(withTimer: true)
      }
      thread.name = "Blink database SSH"
      thread.start()
    }
    return tunnel
  }

  /// Blink's hosts and keys, without prompts: the agent's keys, then a saved
  /// host password. Raw user@host[:port] destinations get Host * defaults.
  private static func clientConfig(for destination: String) throws -> (String, SSHClientConfig) {
    guard let target = DatabaseURL.sshDestination(destination) else {
      throw DatabaseFailure("Enter an SSH host alias or user@host[:port].")
    }
    let bkConfig = try BKConfig()
    var host = try bkConfig.bkSSHHost(target.host)
    if let user = target.user { host.user = user }
    if let port = target.port { host.port = String(port) }
    if host.proxyJump != nil || host.proxyCommand != nil {
      throw DatabaseFailure("\(destination) uses ProxyJump or ProxyCommand, which database tunnels don't support yet.")
    }
    let agent = SSHAgent()
    let constraints: [SSHAgentConstraint] = [SSHConstraintTrustedConnectionOnly()]
    for (signer, name) in bkConfig.signer(forHost: host) ?? bkConfig.defaultSigners() {
      agent.loadKey(signer, aka: name, constraints: constraints)
    }
    var methods: [AuthMethod] = [AuthAgent(agent)]
    if let password = host.password, !password.isEmpty { methods.append(AuthPassword(with: password)) }
    return (host.hostName ?? target.host, host.sshClientConfig(authMethods: methods, agent: agent))
  }

  func openStream(host: String, port: Int) throws -> MySQLTransport {
    guard let (client, runLoop) = lock.withLock({ () -> (SSHClient, RunLoop)? in
      guard alive, let client, let runLoop else { return nil }
      return (client, runLoop)
    }) else { throw DatabaseFailure("The SSH connection closed.") }

    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw DatabaseFailure("Couldn't create a socket pair.") }
    let near = fds[0], far = fds[1]
    let ready = DispatchSemaphore(value: 0)
    var failure: Error?
    runLoop.perform {
      let request = client.requestForward(to: host, port: Int32(port), from: "127.0.0.1", localPort: 0)
        .sink(receiveCompletion: { completion in
          if case .failure(let error) = completion { failure = error; ready.signal() }
        }, receiveValue: { [self] stream in
          streams.append(stream)
          let end = { _ = shutdown(near, SHUT_RDWR) }
          stream.handleCompletion = end
          stream.handleFailure = { _ in end() }
          stream.connect(stdout: DispatchOutputStream(stream: near), stdin: DispatchInputStream(stream: near))
          ready.signal()
        })
      self.cancellables.append(request)
    }
    CFRunLoopWakeUp(runLoop.getCFRunLoop())
    if ready.wait(timeout: .now() + 20) == .timedOut || failure != nil {
      Darwin.close(near); Darwin.close(far)
      throw DatabaseFailure("The SSH server couldn't reach \(host):\(port)" + (failure.map { ": \($0.localizedDescription)" } ?? " (timed out)."))
    }
    return SocketTransport(fd: far)
  }

  func close() {
    let (runLoop, client) = lock.withLock { () -> (RunLoop?, SSHClient?) in
      defer { alive = false; self.client = nil }
      return (self.runLoop, self.client)
    }
    guard let runLoop else { return }
    // libssh isn't thread-safe: cancel the channels and let the client go
    // (its deinit frees the session and stops the run loop) on the SSH thread.
    runLoop.perform { [self] in
      streams.forEach { $0.cancel() }
      streams = []
      cancellables = []
      withExtendedLifetime(client) {}
    }
    CFRunLoopWakeUp(runLoop.getCFRunLoop())
  }
}
