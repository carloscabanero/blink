import Foundation

/// A saved MySQL connection. The password is not part of it: Wink keeps
/// passwords in the Keychain and never hands them to an app's web view.
struct DatabaseConnection: Codable, Equatable {
  var id = UUID().uuidString
  /// The app (manifest id) that saved it. Apps only see their own connections.
  var owner = ""
  var name = ""
  var host = "127.0.0.1"
  var port = 3306
  var user = ""
  var database = ""
  /// A Wink/Blink host alias, or user@host[:port]. Empty connects directly.
  var ssh = ""
  var readOnly = false
  var ssl = false
  /// "", local, development, testing, staging or production.
  var environment = ""
  /// Optional #rrggbb tag, e.g. TablePlus's statusColor.
  var color = ""
  var lastUsed: Date?

  static let environments = ["", "local", "development", "testing", "staging", "production"]

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
    port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 3306
    user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
    database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
    ssh = try c.decodeIfPresent(String.self, forKey: .ssh) ?? ""
    readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    ssl = try c.decodeIfPresent(Bool.self, forKey: .ssl) ?? false
    environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? ""
    color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
    lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
  }

  var title: String {
    if !name.isEmpty { return name }
    let place = ssh.isEmpty ? host : ssh
    return database.isEmpty ? "\(user)@\(place)" : "\(database) on \(place)"
  }

  /// Why this connection can't be used, or nil.
  var problem: String? {
    func unsafe(_ s: String) -> Bool { s.hasPrefix("-") || s.contains(where: { $0.isWhitespace || $0 == "\0" }) }
    if user.isEmpty { return "Enter a user." }
    if host.isEmpty || unsafe(host) { return "Enter a host name without spaces." }
    if !(1...65535).contains(port) { return "Enter a port from 1 to 65535." }
    if database.contains(where: { $0 == ";" || $0.isNewline || $0 == "\0" }) { return "The database name can't contain ; or line breaks." }
    if !ssh.isEmpty && (unsafe(ssh) || DatabaseURL.sshDestination(ssh) == nil) { return "Enter an SSH host alias or user@host[:port]." }
    if !Self.environments.contains(environment) { return "Unknown environment." }
    return nil
  }

  /// What an app sees: everything but the password.
  func json(hasPassword: Bool) -> [String: Any] {
    var out: [String: Any] = ["id": id, "name": name, "title": title, "host": host, "port": port, "user": user,
                              "database": database, "ssh": ssh, "readOnly": readOnly, "ssl": ssl,
                              "environment": environment, "color": color, "hasPassword": hasPassword]
    if let lastUsed { out["lastUsed"] = lastUsed.timeIntervalSince1970 * 1000 }
    return out
  }
}

/// An SSH host Wink knows, used to turn a URL's SSH server into a host alias.
struct DatabaseSSHHost {
  let alias: String
  let hostName: String?
  let user: String?
  let port: Int?
}

/// Reads and writes connection URLs:
///   mysql://user:password@host:3306/database?ssh=alias&ssl=true&name=Shop
///   mariadb://…, jdbc:mysql://…, DATABASE_URL="mysql://…"
///   mysql+ssh://sshuser@sshhost:22/user:password@127.0.0.1:3306/db (TablePlus)
enum DatabaseURL {
  struct Parsed {
    var connection: DatabaseConnection
    var password: String?
  }

  enum Failure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
  }

  /// Text that looks like it is meant to be a connection URL.
  static func looksLikeURL(_ text: String) -> Bool {
    let t = cleaned(text).lowercased()
    return ["mysql://", "mariadb://", "mysql2://", "mysql+ssh://", "mariadb+ssh://"].contains { t.hasPrefix($0) }
  }

  static func parse(_ text: String, sshHosts: [DatabaseSSHHost] = []) throws -> Parsed {
    let input = cleaned(text)
    guard let schemeEnd = input.range(of: "://") else {
      throw Failure.invalid("Paste a URL such as mysql://user:password@host:3306/database.")
    }
    let scheme = input[..<schemeEnd.lowerBound].lowercased()
    var rest = String(input[schemeEnd.upperBound...])
    let overSSH = scheme.hasSuffix("+ssh")
    let base = overSSH ? String(scheme.dropLast(4)) : scheme
    guard ["mysql", "mariadb", "mysql2"].contains(base) else {
      throw Failure.invalid("Only MySQL and MariaDB URLs are supported (this one is \(base)).")
    }

    var connection = DatabaseConnection()
    var password: String?
    var sshHost: String?, sshUser: String?, sshPort: Int?

    if overSSH {
      // sshuser@sshhost:port/dbuser:dbpass@dbhost:port/db
      guard let slash = rest.firstIndex(of: "/") else { throw Failure.invalid("The URL is missing the database part after the SSH server.") }
      let server = try authority(String(rest[..<slash]))
      sshUser = server.user; sshHost = server.host; sshPort = server.port
      rest = String(rest[rest.index(after: slash)...])
    }

    // The last @ before the query separates credentials (which may hold / or :)
    // from the host. If there's no @ before the first ?, the password had a ?.
    let firstQuery = rest.firstIndex(of: "?")
    let beforeQuery = firstQuery.map { String(rest[..<$0]) } ?? rest
    let at = beforeQuery.lastIndex(of: "@").map { rest.index(rest.startIndex, offsetBy: beforeQuery.distance(from: beforeQuery.startIndex, to: $0)) }
      ?? rest.lastIndex(of: "@")
    var hostAndRest = rest
    if let at {
      let credentials = String(rest[..<at])
      hostAndRest = String(rest[rest.index(after: at)...])
      if let colon = credentials.firstIndex(of: ":") {
        connection.user = decode(String(credentials[..<colon]))
        password = decode(String(credentials[credentials.index(after: colon)...]))
      } else {
        connection.user = decode(credentials)
      }
    }
    var query = ""
    if let q = hostAndRest.firstIndex(of: "?") {
      query = String(hostAndRest[hostAndRest.index(after: q)...])
      hostAndRest = String(hostAndRest[..<q])
    }
    if let hash = query.firstIndex(of: "#") { query = String(query[..<hash]) }
    var path = ""
    if let slash = hostAndRest.firstIndex(of: "/") {
      path = String(hostAndRest[hostAndRest.index(after: slash)...])
      hostAndRest = String(hostAndRest[..<slash])
    }
    let server = try authority(hostAndRest)
    if !server.host.isEmpty { connection.host = server.host }
    if let port = server.port { connection.port = port }
    connection.database = decode(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))

    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      let key = parts[0].lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
      let value = parts.count > 1 ? decode(parts[1].replacingOccurrences(of: "+", with: " ")) : ""
      let truthy = ["1", "true", "yes", "on", ""].contains(value.lowercased())
      switch key {
      case "name", "label": connection.name = value
      case "ssh", "sshhost", "sshserver":
        if value.contains("@") || value.contains(":"), let d = sshDestination(value) {
          sshUser = d.user ?? sshUser; sshHost = d.host; sshPort = d.port ?? sshPort
        } else { sshHost = value }
      case "sshuser": sshUser = value
      case "sshport": sshPort = Int(value)
      case "ssl", "usessl", "tls": connection.ssl = truthy
      case "sslmode", "tlsmode":
        connection.ssl = !["disable", "disabled", "false", "0", "allow", "prefer", "preferred"].contains(value.lowercased())
      case "readonly", "safemode": connection.readOnly = truthy
      case "env", "environment":
        let env = value.lowercased()
        let aliases = ["dev": "development", "prod": "production", "test": "testing", "stage": "staging"]
        let mapped = aliases[env] ?? env
        if DatabaseConnection.environments.contains(mapped) { connection.environment = mapped }
      case "statuscolor", "color":
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 6, hex.allSatisfy(\.isHexDigit) { connection.color = "#" + hex.lowercased() }
      case "database", "dbname", "db": connection.database = value
      case "user", "username": connection.user = value
      case "password": password = value
      default: break
      }
    }

    if let sshHost, !sshHost.isEmpty {
      connection.ssh = alias(host: sshHost, user: sshUser, port: sshPort, in: sshHosts)
    }
    if let problem = connection.problem, !connection.user.isEmpty || problem != "Enter a user." {
      throw Failure.invalid(problem)
    }
    return Parsed(connection: connection, password: password?.isEmpty == true ? nil : password)
  }

  /// A URL for the connection. Includes the password only when given one.
  static func format(_ c: DatabaseConnection, password: String? = nil) -> String {
    let userAllowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@/?#"))
    var out = "mysql://" + (c.user.addingPercentEncoding(withAllowedCharacters: userAllowed) ?? c.user)
    if let password, !password.isEmpty {
      out += ":" + (password.addingPercentEncoding(withAllowedCharacters: userAllowed) ?? password)
    }
    let host = c.host.contains(":") ? "[\(c.host)]" : c.host
    out += "@\(host):\(c.port)/" + (c.database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? c.database)
    var params: [(String, String)] = []
    if !c.ssh.isEmpty { params.append(("ssh", c.ssh)) }
    if c.ssl { params.append(("ssl", "true")) }
    if c.readOnly { params.append(("readonly", "true")) }
    if !c.environment.isEmpty { params.append(("env", c.environment)) }
    if !c.color.isEmpty { params.append(("statusColor", String(c.color.dropFirst()))) }
    if !c.name.isEmpty { params.append(("name", c.name)) }
    if !params.isEmpty {
      let valueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
      out += "?" + params.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? $0.1)" }.joined(separator: "&")
    }
    return out
  }

  /// Splits user@host[:port] (or an alias) for the ssh command line.
  static func sshDestination(_ text: String) -> (user: String?, host: String, port: Int?)? {
    guard !text.isEmpty, !text.hasPrefix("-"), !text.contains(where: \.isWhitespace) else { return nil }
    var rest = text
    var user: String?
    if let at = rest.lastIndex(of: "@") {
      user = String(rest[..<at]); rest = String(rest[rest.index(after: at)...])
      if user?.isEmpty == true || user?.hasPrefix("-") == true { return nil }
    }
    guard let parsed = try? authority(rest), !parsed.host.isEmpty, !parsed.host.hasPrefix("-") else { return nil }
    return (user, parsed.host, parsed.port)
  }

  // MARK: - Pieces

  private static func cleaned(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let eq = t.firstIndex(of: "="), t[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
       t[..<eq].first?.isLetter == true {
      t = String(t[t.index(after: eq)...])   // DATABASE_URL=…
    }
    t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
    if t.lowercased().hasPrefix("jdbc:") { t = String(t.dropFirst(5)) }
    return t
  }

  private static func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }

  private static func authority(_ s: String) throws -> (user: String?, host: String, port: Int?) {
    var rest = s
    var user: String?
    if let at = rest.lastIndex(of: "@") {
      user = decode(String(rest[..<at])); rest = String(rest[rest.index(after: at)...])
    }
    if rest.hasPrefix("[") {
      guard let close = rest.firstIndex(of: "]") else { throw Failure.invalid("Unclosed IPv6 address.") }
      let host = String(rest[rest.index(after: rest.startIndex)..<close])
      let after = rest[rest.index(after: close)...]
      guard after.isEmpty || after.hasPrefix(":") else { throw Failure.invalid("Invalid host.") }
      return (user, host, try port(String(after.dropFirst())))
    }
    if let colon = rest.lastIndex(of: ":") {
      return (user, decode(String(rest[..<colon])), try port(String(rest[rest.index(after: colon)...])))
    }
    return (user, decode(rest), nil)
  }

  private static func port(_ s: String) throws -> Int? {
    if s.isEmpty { return nil }
    guard let p = Int(s), (1...65535).contains(p) else { throw Failure.invalid("Invalid port \(s).") }
    return p
  }

  /// Prefers a known host alias; otherwise user@host[:port].
  private static func alias(host: String, user: String?, port: Int?, in hosts: [DatabaseSSHHost]) -> String {
    if user == nil, port == nil, hosts.contains(where: { $0.alias == host }) { return host }
    let match = hosts.first { h in
      (h.hostName ?? h.alias).caseInsensitiveCompare(host) == .orderedSame
        && (user == nil || h.user == nil || h.user == user)
        && (port ?? 22) == (h.port ?? 22)
    }
    if let match, user == nil || match.user == user { return match.alias }
    var out = (user.map { "\($0)@" } ?? "") + (host.contains(":") ? "[\(host)]" : host)
    if let port, port != 22 { out += ":\(port)" }
    return out
  }
}
