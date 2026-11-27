import Foundation
import Security
import CommonCrypto

// A small MySQL/MariaDB client speaking the wire protocol directly, so it runs
// anywhere Foundation does: Wink on macOS and Blink on iOS (no PHP, no
// subprocesses). Platform-neutral: keep this file identical in both hosts.
//
// It is blocking by design: one client per session, used from one serial
// queue. That keeps TLS (SecureTransport over any byte stream, including an
// SSH channel) simple. Close the transport from another thread to unblock it.

// MARK: - Transports

/// A bidirectional byte stream: TCP, TLS on top of another transport, or an
/// SSH channel bridged to a socket.
protocol MySQLTransport: AnyObject {
  /// Blocks until at least one byte is read; 0 means end of stream.
  func read(_ buffer: UnsafeMutableRawBufferPointer) throws -> Int
  func write(_ bytes: UnsafeRawBufferPointer) throws
  /// Safe to call from another thread; wakes a blocked read.
  func close()
}

enum MySQLError: LocalizedError {
  case server(code: Int, state: String, message: String)
  case protocolError(String)
  case io(String)
  case closed

  var errorDescription: String? {
    switch self {
    case .server(let code, _, let message): return "\(message) (\(code))"
    case .protocolError(let m): return "MySQL protocol error: \(m)"
    case .io(let m): return m
    case .closed: return "The connection to the server closed."
    }
  }
}

/// A connected socket file descriptor (TCP, or one end of a socketpair).
final class SocketTransport: MySQLTransport {
  private let fd: Int32
  private let lock = NSLock()
  private var isClosed = false

  init(fd: Int32) {
    self.fd = fd
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  }

  /// Connects with a timeout, trying every address the name resolves to.
  convenience init(host: String, port: Int, timeout: TimeInterval = 15) throws {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var list: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, String(port), &hints, &list)
    guard rc == 0, let first = list else {
      throw MySQLError.io("Can't find \(host): \(String(cString: gai_strerror(rc)))")
    }
    defer { freeaddrinfo(list) }
    var reason = "no addresses"
    var node: UnsafeMutablePointer<addrinfo>? = first
    while let ai = node {
      node = ai.pointee.ai_next
      let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
      guard s >= 0 else { reason = String(cString: strerror(errno)); continue }
      let flags = fcntl(s, F_GETFL)
      _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
      var ok = connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0
      if !ok && errno == EINPROGRESS {
        var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        let n = poll(&pfd, 1, Int32(timeout * 1000))
        if n == 1 {
          var error: Int32 = 0
          var length = socklen_t(MemoryLayout<Int32>.size)
          getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &length)
          ok = error == 0
          if !ok { reason = String(cString: strerror(error)) }
        } else { reason = n == 0 ? "timed out" : String(cString: strerror(errno)) }
      } else if !ok { reason = String(cString: strerror(errno)) }
      if ok {
        _ = fcntl(s, F_SETFL, flags)
        var one: Int32 = 1
        setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        self.init(fd: s)
        return
      }
      Darwin.close(s)
    }
    throw MySQLError.io("Can't connect to \(host):\(port): \(reason).")
  }

  deinit { Darwin.close(fd) }

  func read(_ buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    while true {
      let n = recv(fd, buffer.baseAddress, buffer.count, 0)
      if n >= 0 { return n }
      if errno == EINTR { continue }
      if lock.withLock({ isClosed }) { return 0 }
      throw MySQLError.io(String(cString: strerror(errno)))
    }
  }

  func write(_ bytes: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < bytes.count {
      let n = send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
      if n < 0 {
        if errno == EINTR { continue }
        throw lock.withLock({ isClosed }) ? MySQLError.closed : MySQLError.io(String(cString: strerror(errno)))
      }
      offset += n
    }
  }

  func close() {
    lock.withLock {
      guard !isClosed else { return }
      isClosed = true
      shutdown(fd, SHUT_RDWR)
    }
  }
}

/// TLS on top of another transport, for MySQL's in-band upgrade. Encrypts
/// without verifying the certificate, like mysql --ssl-mode=REQUIRED.
final class TLSTransport: MySQLTransport {
  let inner: MySQLTransport
  private var context: SSLContext!

  init(over inner: MySQLTransport, host: String) throws {
    self.inner = inner
    guard let context = SSLCreateContext(nil, .clientSide, .streamType) else { throw MySQLError.io("TLS isn't available.") }
    self.context = context
    SSLSetIOFuncs(context, tlsRead, tlsWrite)
    SSLSetConnection(context, Unmanaged.passUnretained(self).toOpaque())
    SSLSetSessionOption(context, .breakOnServerAuth, true)
    SSLSetProtocolVersionMin(context, .tlsProtocol1)
    _ = host.withCString { SSLSetPeerDomainName(context, $0, strlen($0)) }
    var status: OSStatus
    repeat { status = SSLHandshake(context) } while status == errSSLPeerAuthCompleted || status == errSSLWouldBlock
    guard status == noErr else { throw MySQLError.io("TLS handshake with the server failed (\(status)).") }
  }

  func read(_ buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    while true {
      var processed = 0
      let status = SSLRead(context, buffer.baseAddress!, buffer.count, &processed)
      if processed > 0 { return processed }
      if status == errSSLClosedGraceful || status == errSSLClosedAbort || status == errSSLClosedNoNotify { return 0 }
      if status != noErr && status != errSSLWouldBlock { throw MySQLError.io("TLS read failed (\(status)).") }
    }
  }

  func write(_ bytes: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < bytes.count {
      var processed = 0
      let status = SSLWrite(context, bytes.baseAddress! + offset, bytes.count - offset, &processed)
      offset += processed
      if status != noErr && status != errSSLWouldBlock { throw MySQLError.io("TLS write failed (\(status)).") }
    }
  }

  func close() { inner.close() }
}

private func tlsRead(_ connection: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
  let transport = Unmanaged<TLSTransport>.fromOpaque(connection).takeUnretainedValue()
  let wanted = length.pointee
  var got = 0
  while got < wanted {
    do {
      let n = try transport.inner.read(UnsafeMutableRawBufferPointer(start: data + got, count: wanted - got))
      if n == 0 { length.pointee = got; return errSSLClosedGraceful }
      got += n
    } catch { length.pointee = got; return errSSLClosedAbort }
  }
  return noErr
}

private func tlsWrite(_ connection: SSLConnectionRef, _ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
  let transport = Unmanaged<TLSTransport>.fromOpaque(connection).takeUnretainedValue()
  do { try transport.inner.write(UnsafeRawBufferPointer(start: data, count: length.pointee)); return noErr }
  catch { length.pointee = 0; return errSSLClosedAbort }
}

// MARK: - Client

struct MySQLConnectOptions {
  var host: String
  var user: String
  var password: String
  var database: String
  var ssl: Bool
}

/// One MySQL session. Not thread-safe: use it from one queue, except close().
final class MySQLClient {
  // Capability flags.
  private static let longPassword: UInt32 = 1, foundRows: UInt32 = 2, longFlag: UInt32 = 4, connectWithDB: UInt32 = 8
  private static let protocol41: UInt32 = 0x200, ssl: UInt32 = 0x800, transactions: UInt32 = 0x2000
  private static let secureConnection: UInt32 = 0x8000, multiResults: UInt32 = 0x20000, psMultiResults: UInt32 = 0x40000
  private static let pluginAuth: UInt32 = 0x80000, pluginAuthLenenc: UInt32 = 0x200000
  // Server status flags.
  private static let moreResults: UInt16 = 0x0008, noBackslashEscapes: UInt16 = 0x0200

  private(set) var transport: MySQLTransport
  private(set) var serverVersion = ""
  private(set) var connectionID: UInt32 = 0
  /// Whether string literals escape with backslashes (false under NO_BACKSLASH_ESCAPES).
  private(set) var backslashEscapes = true
  private var capabilities: UInt32 = 0
  private var sequence: UInt8 = 0
  private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
  private var bufferStart = 0, bufferEnd = 0

  init(transport: MySQLTransport, options: MySQLConnectOptions) throws {
    self.transport = transport
    try handshake(options)
  }

  func close() { transport.close() }

  /// Sends COM_QUIT and closes.
  func quit() {
    sequence = 0
    try? writePacket([0x01])
    transport.close()
  }

  // MARK: Packets

  private func fill(_ count: Int) throws {
    if bufferEnd - bufferStart >= count { return }
    if bufferStart > 0 {
      buffer.replaceSubrange(0..<(bufferEnd - bufferStart), with: buffer[bufferStart..<bufferEnd])
      bufferEnd -= bufferStart
      bufferStart = 0
    }
    if buffer.count < count { buffer += [UInt8](repeating: 0, count: count - buffer.count) }
    while bufferEnd - bufferStart < count {
      let n = try buffer.withUnsafeMutableBytes { raw in
        try transport.read(UnsafeMutableRawBufferPointer(rebasing: raw[bufferEnd...]))
      }
      if n == 0 { throw MySQLError.closed }
      bufferEnd += n
    }
  }

  private func take(_ count: Int) throws -> ArraySlice<UInt8> {
    try fill(count)
    defer { bufferStart += count }
    return buffer[bufferStart..<(bufferStart + count)]
  }

  func readPacket() throws -> [UInt8] {
    var payload = [UInt8]()
    while true {
      let header = try take(4)
      let length = Int(header[header.startIndex]) | Int(header[header.startIndex + 1]) << 8 | Int(header[header.startIndex + 2]) << 16
      sequence = header[header.startIndex + 3] &+ 1
      payload += try take(length)
      if length < 0xFFFFFF { return payload }
    }
  }

  func writePacket(_ payload: [UInt8]) throws {
    var offset = 0
    var data = [UInt8]()
    data.reserveCapacity(payload.count + 8)
    repeat {
      let chunk = min(0xFFFFFF, payload.count - offset)
      data += [UInt8(chunk & 0xFF), UInt8(chunk >> 8 & 0xFF), UInt8(chunk >> 16 & 0xFF), sequence]
      sequence &+= 1
      data += payload[offset..<(offset + chunk)]
      offset += chunk
      if chunk == 0xFFFFFF && offset == payload.count {   // exact multiple: empty trailer
        data += [0, 0, 0, sequence]; sequence &+= 1
      }
    } while offset < payload.count
    try data.withUnsafeBytes { try transport.write($0) }
  }

  // MARK: Handshake and authentication

  private func handshake(_ options: MySQLConnectOptions) throws {
    var p = Reader(try readPacket())
    if p.peek == 0xFF { throw p.error() }
    guard p.byte() == 10 else { throw MySQLError.protocolError("Unsupported server protocol.") }
    serverVersion = p.nulString()
    connectionID = p.uint32()
    var scramble = Array(p.bytes(8))
    p.skip(1)
    var serverCaps = UInt32(p.uint16())
    var plugin = "mysql_native_password"
    if !p.atEnd {
      p.skip(1)                     // character set
      _ = p.uint16()                // status
      serverCaps |= UInt32(p.uint16()) << 16
      let authLength = Int(p.byte())
      p.skip(10)
      if serverCaps & Self.secureConnection != 0 {
        scramble += p.bytes(max(13, authLength - 8)).prefix(12)
      }
      if serverCaps & Self.pluginAuth != 0 { plugin = p.nulString() }
    }
    guard serverCaps & Self.protocol41 != 0 else { throw MySQLError.protocolError("This server is too old (needs MySQL 4.1 or newer).") }

    var caps = Self.longPassword | Self.foundRows | Self.longFlag | Self.protocol41 | Self.transactions
      | Self.secureConnection | Self.multiResults | Self.psMultiResults | Self.pluginAuth | Self.pluginAuthLenenc
    if !options.database.isEmpty { caps |= Self.connectWithDB }
    if options.ssl {
      guard serverCaps & Self.ssl != 0 else { throw MySQLError.io("The server doesn't support SSL/TLS.") }
      caps |= Self.ssl
    }
    caps &= serverCaps
    capabilities = caps

    var head = Writer()
    head.uint32(caps)
    head.uint32(16 * 1024 * 1024)
    head.byte(45)                   // utf8mb4_general_ci
    head.zeros(23)
    if options.ssl {
      try writePacket(head.data)
      transport = try TLSTransport(over: transport, host: options.host)
    }

    var response = head
    response.nulString(options.user)
    let auth = authResponse(plugin: plugin, password: options.password, scramble: scramble, tls: options.ssl)
    if caps & Self.pluginAuthLenenc != 0 { response.lenencBytes(auth) }
    else { response.byte(UInt8(auth.count)); response.bytes(auth) }
    if caps & Self.connectWithDB != 0 { response.nulString(options.database) }
    response.nulString(plugin)
    try writePacket(response.data)
    try finishAuth(plugin: plugin, scramble: scramble, options: options)
  }

  private func authResponse(plugin: String, password: String, scramble: [UInt8], tls: Bool) -> [UInt8] {
    if password.isEmpty { return [] }
    let pw = Array(password.utf8)
    switch plugin {
    case "mysql_native_password":
      let h1 = sha1(pw), h2 = sha1(h1), h3 = sha1(scramble + h2)
      return zip(h1, h3).map { $0 ^ $1 }
    case "caching_sha2_password":
      let h1 = sha256(pw), h2 = sha256(sha256(h1) + scramble)
      return zip(h1, h2).map { $0 ^ $1 }
    case "sha256_password":
      return tls ? pw + [0] : [1]          // 1 asks for the server's public key
    case "mysql_clear_password":
      return tls ? pw + [0] : []
    default:
      return []
    }
  }

  private func finishAuth(plugin startPlugin: String, scramble startScramble: [UInt8], options: MySQLConnectOptions) throws {
    var plugin = startPlugin
    var scramble = startScramble
    let tls = options.ssl
    for _ in 0..<8 {
      var p = Reader(try readPacket())
      switch p.peek {
      case 0x00:
        let ok = p.okPacket()
        backslashEscapes = ok.status & Self.noBackslashEscapes == 0
        return
      case 0xFF:
        throw p.error()
      case 0xFE:                     // auth switch
        p.skip(1)
        plugin = p.nulString()
        scramble = Array(p.rest().prefix(20))
        if plugin == "mysql_clear_password" && !tls {
          throw MySQLError.io("The server asked for the password in clear text; turn on SSL for this connection.")
        }
        try writePacket(authResponse(plugin: plugin, password: options.password, scramble: scramble, tls: tls))
      case 0x01:                     // more data
        p.skip(1)
        let data = Array(p.rest())
        if plugin == "caching_sha2_password" && data == [3] { continue }   // fast auth ok; OK follows
        if plugin == "caching_sha2_password" && data == [4] {               // full auth
          if tls { try writePacket(Array(options.password.utf8) + [0]) }
          else { try writePacket([2]) }                                     // request public key
          continue
        }
        // A PEM public key: encrypt the password with it.
        guard let pem = String(bytes: data, encoding: .utf8), pem.contains("PUBLIC KEY") else {
          throw MySQLError.protocolError("Unexpected authentication data.")
        }
        try writePacket(try rsaEncryptPassword(options.password, scramble: scramble, pem: pem))
      default:
        throw MySQLError.protocolError("Unexpected authentication reply.")
      }
    }
    throw MySQLError.protocolError("Authentication didn't finish.")
  }

  // MARK: Queries

  struct Column {
    var name: String, table: String, type: UInt8, length: UInt32, flags: UInt16, charset: UInt16
  }

  struct Result {
    var columns: [Column] = []
    var rows: [[Any]] = []
    var truncated = false
    var affected: UInt64 = 0
    var insertID: UInt64 = 0
  }

  /// Runs one statement. Extra result sets (CALL) are read and dropped.
  func query(_ sql: String, maxRows: Int = .max, maxCell: Int = .max, maxBytes: Int = 48 << 20) throws -> Result {
    sequence = 0
    try writePacket([0x03] + Array(sql.utf8))
    var first: Result?
    while true {
      let (result, more) = try readResult(maxRows: first == nil ? maxRows : 0, maxCell: maxCell, maxBytes: maxBytes)
      if first == nil { first = result }
      if !more { return first! }
    }
  }

  private func readResult(maxRows: Int, maxCell: Int, maxBytes: Int) throws -> (Result, Bool) {
    var p = Reader(try readPacket())
    switch p.peek {
    case 0x00:
      let ok = p.okPacket()
      backslashEscapes = ok.status & Self.noBackslashEscapes == 0
      return (Result(affected: ok.affected, insertID: ok.insertID), ok.status & Self.moreResults != 0)
    case 0xFF:
      throw p.error()
    case 0xFB:
      throw MySQLError.protocolError("LOAD DATA LOCAL isn't supported.")
    default:
      break
    }
    let count = Int(p.lenenc())
    var result = Result()
    for _ in 0..<count {
      var c = Reader(try readPacket())
      _ = c.lenencString(); _ = c.lenencString()   // catalog, schema
      let table = c.lenencString()
      _ = c.lenencString()                        // org_table
      let name = c.lenencString()
      _ = c.lenencString()                        // org_name
      _ = c.lenenc()
      let charset = c.uint16(), length = c.uint32(), type = c.byte(), flags = c.uint16()
      result.columns.append(Column(name: name, table: table, type: type, length: length, flags: flags, charset: charset))
    }
    if try readPacket().first != 0xFE { throw MySQLError.protocolError("Expected end of column definitions.") }
    var bytes = 0
    while true {
      let packet = try readPacket()
      if packet.first == 0xFE && packet.count < 9 {
        var eof = Reader(packet)
        eof.skip(1)
        _ = eof.uint16()
        let status = eof.uint16()
        backslashEscapes = status & Self.noBackslashEscapes == 0
        return (result, status & Self.moreResults != 0)
      }
      if packet.first == 0xFF { var e = Reader(packet); throw e.error() }
      if result.rows.count >= maxRows || bytes > maxBytes { result.truncated = true; continue }   // drain
      var r = Reader(packet)
      var row = [Any]()
      row.reserveCapacity(count)
      for column in result.columns {
        if r.peek == 0xFB { r.skip(1); row.append(NSNull()); bytes += 4; continue }
        let length = Int(r.lenenc())
        let cell = r.bytes(length)
        row.append(Self.value(cell, binary: column.charset == 63, maxCell: maxCell))
        bytes += min(length, maxCell) + 4
      }
      result.rows.append(row)
    }
  }

  /// Text as a String; long text as {$t: prefix, n: bytes}; bytes that
  /// aren't UTF-8 as {$b: base64 prefix, n: bytes}.
  static func value(_ cell: ArraySlice<UInt8>, binary: Bool, maxCell: Int) -> Any {
    if cell.count <= maxCell, let s = String(bytes: cell, encoding: .utf8) { return s }
    if cell.count > maxCell {
      var end = cell.startIndex + maxCell
      while end > cell.startIndex && cell[end] & 0xC0 == 0x80 { end -= 1 }   // UTF-8 boundary
      if let s = String(bytes: cell[cell.startIndex..<end], encoding: .utf8) {
        return ["$t": s, "n": cell.count]
      }
    }
    return ["$b": Data(cell.prefix(min(maxCell, 4096))).base64EncodedString(), "n": cell.count]
  }

  static func typeName(_ type: UInt8) -> String {
    switch type {
    case 0: return "DECIMAL"; case 1: return "TINY"; case 2: return "SHORT"; case 3: return "LONG"; case 4: return "FLOAT"
    case 5: return "DOUBLE"; case 6: return "NULL"; case 7: return "TIMESTAMP"; case 8: return "LONGLONG"; case 9: return "INT24"
    case 10: return "DATE"; case 11: return "TIME"; case 12: return "DATETIME"; case 13: return "YEAR"; case 15: return "VAR_STRING"
    case 16: return "BIT"; case 245: return "JSON"; case 246: return "NEWDECIMAL"; case 247: return "ENUM"; case 248: return "SET"
    case 249, 250, 251, 252: return "BLOB"; case 253: return "VAR_STRING"; case 254: return "STRING"; case 255: return "GEOMETRY"
    default: return "UNKNOWN"
    }
  }

  static func flagNames(_ flags: UInt16) -> [String] {
    [(1, "not_null"), (2, "primary_key"), (4, "unique_key"), (8, "multiple_key"), (16, "blob"), (32, "unsigned"),
     (128, "binary"), (512, "auto_increment")].filter { flags & $0.0 != 0 }.map(\.1)
  }

  // MARK: Literals

  /// A SQL literal for a bound parameter (strings are quoted and escaped).
  func literal(_ value: Any) -> String {
    switch value {
    case is NSNull: return "NULL"
    case let n as NSNumber:
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" : "0" }
      return n.stringValue
    case let s as String: return quote(s)
    default: return quote(String(describing: value))
    }
  }

  func quote(_ s: String) -> String {
    var out = "'"
    out.reserveCapacity(s.utf8.count + 2)
    for ch in s.unicodeScalars {
      switch ch {
      case "'": out += backslashEscapes ? "\\'" : "''"
      case "\\" where backslashEscapes: out += "\\\\"
      case "\0" where backslashEscapes: out += "\\0"
      case "\n" where backslashEscapes: out += "\\n"
      case "\r" where backslashEscapes: out += "\\r"
      case "\u{1A}" where backslashEscapes: out += "\\Z"
      default: out.unicodeScalars.append(ch)
      }
    }
    return out + "'"
  }

  /// Replaces each `?` outside quotes, identifiers and comments with a literal.
  func bind(_ sql: String, _ params: [Any]) throws -> String {
    if params.isEmpty { return sql }
    let s = Array(sql.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0, used = 0
    while i < s.count {
      let c = s[i]
      if c == "'" || c == "\"" || c == "`" {
        out.append(c); i += 1
        while i < s.count {
          out.append(s[i])
          if s[i] == "\\" && c != "`" && backslashEscapes, i + 1 < s.count { out.append(s[i + 1]); i += 2; continue }
          if s[i] == c { if i + 1 < s.count && s[i + 1] == c { out.append(s[i + 1]); i += 2; continue }; i += 1; break }
          i += 1
        }
      } else if c == "#" || (c == "-" && i + 2 < s.count && s[i + 1] == "-" && s[i + 2].properties.isWhitespace) {
        while i < s.count && s[i] != "\n" { out.append(s[i]); i += 1 }
      } else if c == "/" && i + 1 < s.count && s[i + 1] == "*" {
        out.append(c); out.append(s[i + 1]); i += 2
        while i < s.count && !(s[i] == "*" && i + 1 < s.count && s[i + 1] == "/") { out.append(s[i]); i += 1 }
        if i < s.count { out.append(s[i]); out.append(s[i + 1]); i += 2 }
      } else if c == "?" {
        guard used < params.count else { throw MySQLError.protocolError("The statement has more ? placeholders than values.") }
        out.append(contentsOf: literal(params[used]).unicodeScalars); used += 1; i += 1
      } else { out.append(c); i += 1 }
    }
    guard used == params.count else { throw MySQLError.protocolError("The statement has fewer ? placeholders than values.") }
    return String(out)
  }
}

// MARK: - Crypto

private func sha1(_ data: [UInt8]) -> [UInt8] {
  var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
  data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
  return digest
}

private func sha256(_ data: [UInt8]) -> [UInt8] {
  var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
  data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
  return digest
}

/// caching_sha2/sha256 full authentication without TLS: RSA-OAEP over
/// (password + NUL) XOR scramble, with the server's public key.
private func rsaEncryptPassword(_ password: String, scramble: [UInt8], pem: String) throws -> [UInt8] {
  let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
  guard let der = Data(base64Encoded: body) else { throw MySQLError.protocolError("Unreadable server public key.") }
  let plain = (Array(password.utf8) + [0]).enumerated().map { $0.element ^ scramble[$0.offset % max(1, scramble.count)] }
  let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
  var error: Unmanaged<CFError>?
  guard let key = SecKeyCreateWithData(pkcs1(fromSPKI: der) as CFData, attributes as CFDictionary, &error),
        let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(plain) as CFData, &error) as Data? else {
    throw MySQLError.protocolError("Couldn't encrypt the password with the server's key.")
  }
  return Array(encrypted)
}

/// Strips a SubjectPublicKeyInfo wrapper down to the PKCS#1 RSAPublicKey
/// that SecKeyCreateWithData wants. Returns the input if it isn't SPKI.
private func pkcs1(fromSPKI der: Data) -> Data {
  let b = [UInt8](der)
  var i = 0
  func length() -> Int? {
    guard i < b.count else { return nil }
    var n = Int(b[i]); i += 1
    if n & 0x80 != 0 {
      let count = n & 0x7F
      guard count <= 4, i + count <= b.count else { return nil }
      n = 0
      for _ in 0..<count { n = n << 8 | Int(b[i]); i += 1 }
    }
    return n
  }
  guard b.first == 0x30 else { return der }
  i = 1
  guard length() != nil, i < b.count, b[i] == 0x30 else { return der }
  i += 1
  guard let algorithm = length() else { return der }
  i += algorithm                                  // skip AlgorithmIdentifier
  guard i < b.count, b[i] == 0x03 else { return der }
  i += 1
  guard length() != nil, i < b.count else { return der }
  i += 1                                          // unused-bits byte
  return Data(b[i...])
}

// MARK: - Encoding helpers

private struct Reader {
  let data: [UInt8]
  var i = 0
  init(_ data: [UInt8]) { self.data = data }
  var atEnd: Bool { i >= data.count }
  var peek: UInt8? { i < data.count ? data[i] : nil }
  mutating func byte() -> UInt8 { defer { i += 1 }; return i < data.count ? data[i] : 0 }
  mutating func skip(_ n: Int) { i = min(data.count, i + n) }
  mutating func bytes(_ n: Int) -> ArraySlice<UInt8> {
    let end = min(data.count, i + n)
    defer { i = end }
    return data[min(i, end)..<end]
  }
  mutating func rest() -> ArraySlice<UInt8> { bytes(data.count - i) }
  mutating func uint16() -> UInt16 { UInt16(byte()) | UInt16(byte()) << 8 }
  mutating func uint32() -> UInt32 { UInt32(uint16()) | UInt32(uint16()) << 16 }
  mutating func lenenc() -> UInt64 {
    let first = byte()
    switch first {
    case 0xFC: return UInt64(uint16())
    case 0xFD: return UInt64(byte()) | UInt64(byte()) << 8 | UInt64(byte()) << 16
    case 0xFE: return UInt64(uint32()) | UInt64(uint32()) << 32
    default: return UInt64(first)
    }
  }
  mutating func lenencString() -> String { String(decoding: bytes(Int(lenenc())), as: UTF8.self) }
  mutating func nulString() -> String {
    let start = i
    while i < data.count && data[i] != 0 { i += 1 }
    defer { i += 1 }
    return String(decoding: data[start..<min(i, data.count)], as: UTF8.self)
  }
  mutating func okPacket() -> (affected: UInt64, insertID: UInt64, status: UInt16) {
    skip(1)
    let affected = lenenc(), insertID = lenenc()
    return (affected, insertID, uint16())
  }
  mutating func error() -> MySQLError {
    skip(1)
    let code = Int(uint16())
    var state = ""
    if peek == UInt8(ascii: "#") { skip(1); state = String(decoding: bytes(5), as: UTF8.self) }
    return .server(code: code, state: state, message: String(decoding: rest(), as: UTF8.self))
  }
}

private struct Writer {
  var data = [UInt8]()
  mutating func byte(_ b: UInt8) { data.append(b) }
  mutating func bytes(_ b: [UInt8]) { data += b }
  mutating func zeros(_ n: Int) { data += [UInt8](repeating: 0, count: n) }
  mutating func uint32(_ v: UInt32) { data += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
  mutating func nulString(_ s: String) { data += Array(s.utf8) + [0] }
  mutating func lenencBytes(_ b: [UInt8]) {
    if b.count < 251 { data.append(UInt8(b.count)) }
    else if b.count < 1 << 16 { data += [0xFC, UInt8(b.count & 0xFF), UInt8(b.count >> 8)] }
    else { data += [0xFD, UInt8(b.count & 0xFF), UInt8(b.count >> 8 & 0xFF), UInt8(b.count >> 16)] }
    data += b
  }
}
