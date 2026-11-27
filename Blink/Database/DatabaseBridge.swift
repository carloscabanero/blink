import Foundation
import Security

// The `blink.database` API for one app tab, shared by Wink (macOS) and Blink
// (iOS). Platform-neutral: keep this file identical in both hosts. Each host
// supplies dialogs (DatabaseHostUI) and SSH tunnels (DatabaseTunnel).
//
// Connections are edited in native dialogs and passwords live in the
// Keychain; neither reaches the app's web view. An app sees only the
// connections it saved.

/// Native dialogs. Every call may suspend while the person answers.
@MainActor protocol DatabaseHostUI: AnyObject {
  /// The connection form. Returns the edited connection and the password
  /// field's text, or nil when cancelled. `problem` explains a failed save.
  func editConnection(_ draft: DatabaseConnection, password: String?, hasSavedPassword: Bool, title: String,
                      problem: String?, sshHosts: [DatabaseSSHHost]) async -> (connection: DatabaseConnection, password: String)?
  func askForURL(prefill: String, problem: String?) async -> String?
  func confirmRemove(_ connection: DatabaseConnection) async -> Bool
  /// nil cancels; true copies the URL with its password.
  func askIncludePassword(_ connection: DatabaseConnection) async -> Bool?
  func setClipboard(_ text: String)
  func clipboard() -> String?
}

/// An SSH connection that opens channels to host:port as seen from the server.
protocol DatabaseTunnel: AnyObject {
  var isAlive: Bool { get }
  /// Called on a background queue; may block.
  func openStream(host: String, port: Int) throws -> MySQLTransport
  func close()
}

struct DatabaseHostEnvironment {
  var storeURL: URL
  var keychainService: String
  var sshHosts: () -> [DatabaseSSHHost]
  /// Opens an SSH connection to an alias or user@host[:port].
  var openTunnel: (_ destination: String) async throws -> DatabaseTunnel
}

struct DatabaseFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

@MainActor final class DatabaseBridge {
  private let appName: String
  private let owner: String
  private let environment: DatabaseHostEnvironment
  private weak var ui: DatabaseHostUI?
  private let keychain: DatabaseKeychain

  private var closed = false
  private var active: DatabaseConnection?
  private var activePassword = ""
  private var tunnel: DatabaseTunnel?
  private let session = DatabaseSession()
  private var currentDatabase = ""
  private var busy = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(appName: String, owner: String, environment: DatabaseHostEnvironment, ui: DatabaseHostUI) {
    self.appName = appName
    self.owner = owner
    self.environment = environment
    self.ui = ui
    self.keychain = DatabaseKeychain(service: environment.keychainService)
  }

  static let capabilities = ["database"]

  func close() {
    closed = true
    disconnect()
    for waiter in waiting { waiter.resume() }
    waiting = []
  }

  private func disconnect() {
    session.closeClient()
    tunnel?.close(); tunnel = nil
    active = nil; activePassword = ""; currentDatabase = ""
  }

  // MARK: - Methods

  func call(_ method: String, _ args: [String: Any]) async throws -> Any {
    guard !closed else { throw DatabaseFailure("This app tab has closed.") }
    guard let ui else { throw DatabaseFailure("This app tab has closed.") }
    switch method {
    case "database.connections":
      return load().filter { $0.owner == owner }
        .sorted { ($0.lastUsed ?? .distantPast, $1.title) > ($1.lastUsed ?? .distantPast, $0.title) }
        .map { $0.json(hasPassword: keychain.has($0.id)) }
    case "database.sshHosts":
      return environment.sshHosts().map(\.alias)
    case "database.edit":
      let existing = try (args["id"] as? String).map(connection)
      guard let saved = try await edit(existing, password: nil, title: existing == nil ? "New MySQL Connection" : "Edit Connection") else { return NSNull() }
      return saved.json(hasPassword: keychain.has(saved.id))
    case "database.importURL":
      guard let saved = try await importURL(ui) else { return NSNull() }
      return saved.json(hasPassword: keychain.has(saved.id))
    case "database.duplicate":
      var copy = try connection(args["id"] as? String ?? "")
      let password = keychain.get(copy.id)
      copy.id = UUID().uuidString; copy.name = copy.title + " copy"; copy.lastUsed = nil
      try save(copy, password: password)
      return copy.json(hasPassword: password != nil)
    case "database.remove":
      let existing = try connection(args["id"] as? String ?? "")
      guard await ui.confirmRemove(existing) else { return false }
      store(load().filter { $0.id != existing.id })
      keychain.delete(existing.id)
      return true
    case "database.copyURL":
      let existing = try connection(args["id"] as? String ?? "")
      let password = keychain.get(existing.id)
      var include = false
      if password != nil {
        guard let choice = await ui.askIncludePassword(existing) else { return false }
        include = choice
      }
      ui.setClipboard(DatabaseURL.format(existing, password: include ? password : nil))
      return true
    case "database.open":
      return try await open(connection(args["id"] as? String ?? ""))
    case "database.connect":
      // v0.2 API: pick a connection in a dialog and open it.
      guard let picked = try await edit(nil, password: nil, title: "Connect to MySQL") else { return false }
      _ = try await open(picked)
      return true
    case "database.status":
      guard let active else { return ["connected": false] }
      return ["connected": true, "connection": active.json(hasPassword: !activePassword.isEmpty), "database": currentDatabase, "busy": busy]
    case "database.disconnect":
      await acquire(); defer { release() }
      disconnect()
      return true
    case "database.cancel":
      await cancel()
      return true
    case "database.query":
      guard let sql = args["sql"] as? String, !sql.isEmpty, sql.utf8.count <= 4 << 20 else {
        throw DatabaseFailure("Enter a query of up to 4 MiB.")
      }
      let params = args["params"] as? [Any] ?? []
      let maxRows = min(max(args["maxRows"] as? Int ?? 1000, 1), 50000)
      let maxCell = min(max(args["maxCell"] as? Int ?? 65536, 256), 16 << 20)
      return try await run { [session] readOnly in try session.query(sql, params: params, maxRows: maxRows, maxCell: maxCell, readOnly: readOnly) }
    case "database.execute":
      guard let statements = args["statements"] as? [[String: Any]], statements.count <= 10000 else {
        throw DatabaseFailure("Send up to 10,000 statements.")
      }
      let list = statements.map { (sql: $0["sql"] as? String ?? "", params: $0["params"] as? [Any] ?? []) }
      return try await run { [session] readOnly in try session.execute(list, readOnly: readOnly) }
    default:
      throw DatabaseFailure("Unsupported database method.")
    }
  }

  // MARK: - Saved connections

  func load() -> [DatabaseConnection] {
    guard let data = try? Data(contentsOf: environment.storeURL) else { return [] }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([DatabaseConnection].self, from: data)) ?? []
  }

  private func store(_ connections: [DatabaseConnection]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(connections) else { return }
    let url = environment.storeURL
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func connection(_ id: String) throws -> DatabaseConnection {
    guard let found = load().first(where: { $0.id == id && $0.owner == owner }) else {
      throw DatabaseFailure("That connection no longer exists.")
    }
    return found
  }

  private func save(_ connection: DatabaseConnection, password: String?) throws {
    var c = connection
    c.owner = owner
    if let password {
      if password.isEmpty { keychain.delete(c.id) } else { try keychain.set(password, for: c.id) }
    }
    store(load().filter { $0.id != c.id } + [c])
  }

  private func touch(_ id: String) {
    var all = load()
    if let i = all.firstIndex(where: { $0.id == id }) { all[i].lastUsed = Date(); store(all) }
  }

  // MARK: - Dialogs

  private func importURL(_ ui: DatabaseHostUI) async throws -> DatabaseConnection? {
    var text = ui.clipboard().flatMap { DatabaseURL.looksLikeURL($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? ""
    var problem: String?
    while true {
      guard let entered = await ui.askForURL(prefill: text, problem: problem), !closed else { return nil }
      text = entered
      do {
        let parsed = try DatabaseURL.parse(entered, sshHosts: environment.sshHosts())
        return try await edit(parsed.connection, password: parsed.password, title: "Import Connection", isNew: true)
      } catch let error as DatabaseURL.Failure {
        problem = error.localizedDescription
      }
    }
  }

  private func edit(_ existing: DatabaseConnection?, password: String?, title: String, isNew: Bool? = nil) async throws -> DatabaseConnection? {
    let creating = isNew ?? (existing == nil)
    var draft = existing ?? DatabaseConnection()
    var typed = password
    var problem: String?
    while true {
      guard let ui, let answer = await ui.editConnection(draft, password: typed, hasSavedPassword: !creating && keychain.has(draft.id),
                                                         title: title, problem: problem, sshHosts: environment.sshHosts()),
            !closed else { return nil }
      draft = answer.connection
      typed = answer.password
      if let p = draft.problem { problem = p; continue }
      // A blank password keeps the saved one when editing.
      try save(draft, password: answer.password.isEmpty && !creating ? nil : answer.password)
      return draft
    }
  }

  // MARK: - Session

  /// One statement at a time per tab; later calls wait their turn.
  private func acquire() async {
    if !busy { busy = true; return }
    await withCheckedContinuation { waiting.append($0) }   // busy stays true: handed over
  }

  private func release() {
    if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
  }

  private func open(_ connection: DatabaseConnection) async throws -> Any {
    await acquire(); defer { release() }
    guard !closed else { throw DatabaseFailure("This app tab has closed.") }
    disconnect()
    let password = keychain.get(connection.id) ?? ""
    let info = try await start(connection, password: password, database: connection.database)
    active = connection
    activePassword = password
    touch(connection.id)
    return ["connection": connection.json(hasPassword: !password.isEmpty), "version": info.version,
            "database": info.database.isEmpty ? NSNull() : info.database, "thread": info.thread]
  }

  /// Opens the tunnel (if needed) and a session on `database`.
  private func start(_ c: DatabaseConnection, password: String, database: String) async throws -> DatabaseSession.Info {
    if !c.ssh.isEmpty, tunnel?.isAlive != true {
      tunnel?.close()
      tunnel = nil
      tunnel = try await environment.openTunnel(c.ssh)
    }
    let endpoint = DatabaseSession.Endpoint(connection: c, password: password, tunnel: tunnel)
    let info = try await session.connect(endpoint, database: database)
    guard !closed else { session.closeClient(); throw DatabaseFailure("This app tab has closed.") }
    currentDatabase = info.database
    return info
  }

  private func run(_ work: @escaping (_ readOnly: Bool) throws -> [String: Any]) async throws -> Any {
    await acquire(); defer { release() }
    guard !closed else { throw DatabaseFailure("This app tab has closed.") }
    guard let active else { throw DatabaseFailure("Open a connection first.") }
    var reconnected = false
    if !session.isConnected || tunnel.map({ !$0.isAlive }) == true {
      // Stopped (cancel), dropped, or the tunnel closed: reconnect to the
      // database the session had selected.
      session.closeClient()
      _ = try await start(active, password: activePassword, database: currentDatabase.isEmpty ? active.database : currentDatabase)
      reconnected = true
    }
    var reply = try await session.perform { try work(active.readOnly) }
    if reconnected { reply["reconnected"] = true }
    if let database = reply.removeValue(forKey: "_database") as? String { currentDatabase = database }
    return reply
  }

  /// Asks the server to stop the running statement from a second connection;
  /// if that doesn't work quickly, drops the session (the next query reconnects).
  private func cancel() async {
    guard busy, active != nil else { return }
    let stopped = await session.killRunningQuery()
    if stopped {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard session.isRunning else { return }
    }
    session.closeClient()
  }
}

// MARK: - Session (one MySQL connection, on its own queue)

final class DatabaseSession: @unchecked Sendable {
  struct Endpoint: @unchecked Sendable {
    let connection: DatabaseConnection
    let password: String
    let tunnel: DatabaseTunnel?

    func transport(timeout: TimeInterval = 15) throws -> MySQLTransport {
      if let tunnel { return try tunnel.openStream(host: connection.host, port: connection.port) }
      return try SocketTransport(host: connection.host, port: connection.port, timeout: timeout)
    }
  }

  struct Info { let version: String; let thread: Int; let database: String }

  private let queue = DispatchQueue(label: "database.session")
  private let lock = NSLock()
  private var client: MySQLClient?
  private var endpoint: Endpoint?
  private var running = false

  var isConnected: Bool { lock.withLock { client != nil } }
  var isRunning: Bool { lock.withLock { running } }

  func closeClient() {
    let old = lock.withLock { () -> MySQLClient? in defer { client = nil }; return client }
    old?.close()
  }

  private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try work() }) }
    }
  }

  func connect(_ endpoint: Endpoint, database: String) async throws -> Info {
    try await onQueue { [self] in
      closeClient()
      let c = endpoint.connection
      let client = try MySQLClient(transport: endpoint.transport(),
                                   options: MySQLConnectOptions(host: c.host, user: c.user, password: endpoint.password, database: database, ssl: c.ssl))
      if c.readOnly { _ = try client.query("SET SESSION TRANSACTION READ ONLY") }
      let current = try client.query("SELECT DATABASE()").rows.first?.first as? String ?? ""
      lock.withLock { self.client = client; self.endpoint = endpoint }
      return Info(version: client.serverVersion, thread: Int(client.connectionID), database: current)
    }
  }

  /// Runs `work` on the session queue. A dropped connection is forgotten so
  /// the next call reconnects.
  func perform(_ work: @escaping () throws -> [String: Any]) async throws -> [String: Any] {
    try await onQueue { [self] in
      lock.withLock { running = true }
      defer { lock.withLock { running = false } }
      do { return try work() }
      catch let error as MySQLError {
        switch error {
        case .closed, .io:
          closeClient()
          throw DatabaseFailure("The query was stopped or the connection dropped. The next query reconnects.")
        default: throw error
        }
      }
    }
  }

  private func current() throws -> MySQLClient {
    guard let client = lock.withLock({ client }) else { throw MySQLError.closed }
    return client
  }

  private static let liftReadOnly = try! NSRegularExpression(
    pattern: #"^\s*(/\*.*?\*/\s*)*SET\b[^;]*\b(TRANSACTION|transaction_read_only|tx_read_only)\b"#,
    options: [.caseInsensitive, .dotMatchesLineSeparators])

  private func guardReadOnly(_ sql: String, _ readOnly: Bool) throws {
    if readOnly, Self.liftReadOnly.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)) != nil {
      throw DatabaseFailure("This connection is read-only.")
    }
  }

  func query(_ sql: String, params: [Any], maxRows: Int, maxCell: Int, readOnly: Bool) throws -> [String: Any] {
    try guardReadOnly(sql, readOnly)
    let client = try current()
    let started = Date()
    let result = try client.query(try client.bind(sql, params), maxRows: maxRows, maxCell: maxCell)
    let elapsed = Date().timeIntervalSince(started) * 1000
    var reply: [String: Any]
    if result.columns.isEmpty {
      reply = ["columns": [Any](), "rows": [Any](), "truncated": false, "affected": result.affected,
               "insertId": result.insertID == 0 ? NSNull() : String(result.insertID), "elapsed": elapsed]
    } else {
      reply = ["columns": result.columns.map { c -> [String: Any] in
                 ["name": c.name, "table": c.table, "type": MySQLClient.typeName(c.type), "length": c.length, "flags": MySQLClient.flagNames(c.flags)] },
               "rows": result.rows, "truncated": result.truncated, "elapsed": elapsed]
    }
    if sql.range(of: #"^\s*use\s"#, options: [.regularExpression, .caseInsensitive]) != nil {
      reply["_database"] = (try? client.query("SELECT DATABASE()"))?.rows.first?.first as? String ?? ""
    }
    return reply
  }

  /// All statements in one transaction, or none.
  func execute(_ statements: [(sql: String, params: [Any])], readOnly: Bool) throws -> [String: Any] {
    let client = try current()
    if statements.isEmpty { return ["affected": [Int]()] }
    _ = try client.query("START TRANSACTION")
    var affected: [Int] = []
    var insertID: UInt64 = 0
    for (index, statement) in statements.enumerated() {
      do {
        try guardReadOnly(statement.sql, readOnly)
        let result = try client.query(try client.bind(statement.sql, statement.params), maxRows: 0)
        affected.append(Int(result.affected))
        if result.insertID != 0 { insertID = result.insertID }
      } catch {
        _ = try? client.query("ROLLBACK")
        if case MySQLError.closed = error { throw error }
        if case MySQLError.io = error { throw error }
        throw DatabaseFailure("Statement \(index + 1): \(error.localizedDescription)")
      }
    }
    _ = try client.query("COMMIT")
    return ["affected": affected, "insertId": insertID == 0 ? NSNull() : String(insertID)]
  }

  /// KILL QUERY from a second connection. Called while the queue is busy.
  func killRunningQuery() async -> Bool {
    guard let (endpoint, thread) = lock.withLock({ () -> (Endpoint, UInt32)? in
      guard let endpoint, let client else { return nil }
      return (endpoint, client.connectionID)
    }) else { return false }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        var killer: MySQLClient?
        let timer = DispatchWorkItem { killer?.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: timer)
        defer { timer.cancel() }
        do {
          let c = endpoint.connection
          killer = try MySQLClient(transport: endpoint.transport(timeout: 5),
                                   options: MySQLConnectOptions(host: c.host, user: c.user, password: endpoint.password, database: "", ssl: c.ssl))
          _ = try killer!.query("KILL QUERY \(thread)")
          killer!.quit()
          continuation.resume(returning: true)
        } catch {
          killer?.close()
          continuation.resume(returning: false)
        }
      }
    }
  }
}

// MARK: - Keychain

struct DatabaseKeychain {
  let service: String

  private func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  func get(_ account: String) -> String? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func has(_ account: String) -> Bool {
    var q = query(account)
    q[kSecReturnAttributes as String] = true
    return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
  }

  func set(_ value: String, for account: String) throws {
    let data = Data(value.utf8)
    var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = query(account)
      add[kSecValueData as String] = data
      add[kSecAttrLabel as String] = service
      add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw DatabaseFailure("Couldn't save the password in the Keychain (\(status)).") }
  }

  func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
