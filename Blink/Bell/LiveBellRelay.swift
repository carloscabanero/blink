import Combine
import CryptoKit
import Foundation
import Security

// These synchronous methods only persist desired operations. Network I/O is
// asynchronous and never blocks a menu, Terminal close, or the main thread.
enum BellOperationStatus: Equatable {
  case pending, confirmed, expired
  case retrying(String)
  var description: String {
    switch self {
    case .pending: return "Pending Relay confirmation"
    case .confirmed: return "Relay confirmed"
    case .expired: return "Bell expired"
    case .retrying(let reason): return reason
    }
  }
}

@MainActor protocol BellPurchaseProofProvider {
  func enrollmentProof() async throws -> String
}

@MainActor protocol BellRelayOperations {
  func operationStatus(for id: UUID) -> AnyPublisher<BellOperationStatus, Never>
  func setActive(_ active: Bool)
  func updateEndpoint(_ token: Data)
  func fetchState(since: [UUID: Int64]) async throws -> [(UUID, Bell.ReceivedState)]
  func submitVerdict(bellID: UUID, askID: String, verdict: String) async throws -> String
  func createBell(name: String, ownerID: UUID?) throws -> Bell
  func bind(_ id: UUID, bellKey: String, apnsToken: Data?, level: Bell.ReceiveLevel) throws -> Bell.RelayBindingResponse
  func unbind(_ id: UUID, bellKey: String) throws
  func deleteBell(_ id: UUID, bellKey: String) throws
}

extension BellRelayOperations {
  func operationStatus(for id: UUID) -> AnyPublisher<BellOperationStatus, Never> { Just(.confirmed).eraseToAnyPublisher() }
  func setActive(_ active: Bool) {}
  func updateEndpoint(_ token: Data) {}
  func fetchState(since: [UUID: Int64]) async throws -> [(UUID, Bell.ReceivedState)] { [] }
  func submitVerdict(bellID: UUID, askID: String, verdict: String) async throws -> String { "unavailable" }
}

extension MockBellRelay: BellRelayOperations {
  func createBell(name: String, ownerID: UUID?) throws -> Bell { try createBell(name: name) }
}

@MainActor final class LiveBellRelay: BellRelayOperations {
  struct Configuration {
    let baseURL: URL
    let topic: String
    let environment: String
    var isValid: Bool {
      (baseURL.scheme == "https" || (baseURL.scheme == "http" && ["127.0.0.1", "localhost"].contains(baseURL.host ?? ""))) &&
      baseURL.host != nil && baseURL.user == nil && baseURL.password == nil && baseURL.query == nil && baseURL.fragment == nil &&
      (baseURL.path.isEmpty || baseURL.path == "/") && !topic.isEmpty && ["sandbox", "production"].contains(environment)
    }
  }

  struct Record: Codable {
    let bell: Bell
    let ownerID: UUID?
    var revision = 0
    var ready = false
    var provisioned = false
    var retired = false
    var expired = false
    var pending = true
    var level: Bell.ReceiveLevel?
    var operationError: String?
  }
  struct Submission: Codable {
    let bellID: UUID
    let askID: String
    let verdict: String
    let mac: String
    var status = "submitting"
  }
  struct Journal: Codable {
    var submissions: [Submission]? = nil
    var relayOrigin: String?
    var deviceID: String?
    var mintKey: String?
    var endpointKey: String
    var records: [Record] = []
  }
  enum Failure: LocalizedError {
    case configuration, localCredentials, missingEnrollment, missingAPNsToken, missingDevice, randomGeneration, enrollmentRejected(Int), response(Int), invalidResponse, missingRecord, expired
    var errorDescription: String? {
      switch self {
      case .configuration: return "Relay configuration is invalid or differs from this installation's saved Relay origin."
      case .localCredentials: return "Saved Bell credentials are invalid or unavailable. Enrollment tokens cannot repair a Bell's local keys."
      case .missingEnrollment: return "No eligible paid entitlement or enrollment token is available. Restore an eligible purchase, or set BELL_PAID_TOKEN in Xcode Run environment variables for a development Relay."
      case .missingAPNsToken: return "Waiting for an APNs device token. Launch on a push-enabled signed device and check APNs registration. Bell binding remains pending."
      case .missingDevice: return "Relay device enrollment is incomplete: the saved device ID is missing."
      case .randomGeneration: return "The system could not generate secure Bell credentials."
      case .enrollmentRejected(let code): return "Relay enrollment failed (HTTP \(code)). Check purchase eligibility and Relay purchase mode; production does not accept dev tokens."
      case .response(let code): return "Relay request failed (HTTP \(code)). Changes remain pending."
      case .invalidResponse: return "The Relay returned an invalid response."
      case .missingRecord: return "This Bell is not in the Relay operation journal."
      case .expired: return "This Bell has expired. Create a replacement explicitly."
      }
    }
  }

  private let proofProvider: any BellPurchaseProofProvider
  private var statusSubjects: [UUID: CurrentValueSubject<BellOperationStatus, Never>] = [:]
  private var active = false
  private var endpoint: Data?
  private var retryTask: Task<Void, Never>?
  private var retryDelay: UInt64 = 2
  private var syncAgain = false
  private let configuration: Configuration?
  private let journalURL: URL
  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  }
  private let session: URLSession
  private var journal: Journal
  private var syncing = false
  var hasPendingOperations: Bool { journal.records.contains { $0.ready && $0.pending && !$0.expired } || journal.submissions?.contains { $0.status == "submitting" } == true }
  private(set) var lastError: String?

  init(configuration: Configuration?, proofProvider: any BellPurchaseProofProvider, journalURL: URL? = nil, session: URLSession? = nil) throws {
    self.configuration = configuration
    self.proofProvider = proofProvider
    self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    self.journalURL = try journalURL ?? FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Bell/RelayOperations.json")
    do { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: self.journalURL)) }
    catch CocoaError.fileReadNoSuchFile { journal = Journal(endpointKey: try Self.random(32).base64EncodedString()) }
    if let origin = journal.relayOrigin, let configuration = configuration,
       origin != configuration.baseURL.absoluteString { throw Failure.configuration }
    if journal.relayOrigin == nil { journal.relayOrigin = configuration?.baseURL.absoluteString }
    // Corrupt/unreadable journals must never reset credentials or duplicate Bells.
  }

  private func status(_ record: Record) -> BellOperationStatus {
    if record.expired { return .expired }
    if !record.pending { return .confirmed }
    if let error = record.operationError { return .retrying(error) }
    return .pending
  }

  func operationStatus(for id: UUID) -> AnyPublisher<BellOperationStatus, Never> {
    if let subject = statusSubjects[id] { return subject.eraseToAnyPublisher() }
    let subject = CurrentValueSubject<BellOperationStatus, Never>(journal.records.first(where: { $0.bell.id == id }).map(status) ?? .expired)
    statusSubjects[id] = subject
    return subject.eraseToAnyPublisher()
  }

  func setActive(_ active: Bool) {
    self.active = active
    if active { kick() } else { retryTask?.cancel(); retryTask = nil }
  }

  func updateEndpoint(_ token: Data) { endpoint = token; kick() }

  // Relay owns operation scheduling. Tower only supplies lifecycle/endpoint events.
  private func kick(after delay: UInt64 = 0) {
    guard active else { return }
    retryTask?.cancel()
    retryTask = Task { @MainActor [weak self] in
      if delay > 0 {
        do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
      }
      guard let self = self, self.active, !Task.isCancelled else { return }
      self.retryTask = nil
      do { try await self.synchronize(apnsToken: self.endpoint) } catch { }
    }
  }

  static func random(_ count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    guard status == errSecSuccess else { throw Failure.randomGeneration }
    return data
  }
  static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
  static func wireID(_ id: UUID) -> String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
  static func url64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  private func save(_ value: Journal) throws {
    let folder = journalURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var url = journalURL
    var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
    try url.setResourceValues(attributes)
    journal = value
    for record in value.records { statusSubjects[record.bell.id]?.send(status(record)) }
  }
  private func change(_ id: UUID, key: String, allowRetired: Bool = false, _ update: (inout Record) -> Void) throws {
    var value = journal
    guard let index = value.records.firstIndex(where: { $0.bell.id == id && $0.bell.bellKey == key }) else { throw Failure.missingRecord }
    guard allowRetired || (!value.records[index].expired && !value.records[index].retired) else { throw Failure.expired }
    update(&value.records[index]); value.records[index].revision += 1; value.records[index].pending = true; value.records[index].operationError = nil
    try save(value)
    kick()
  }

  func createBell(name: String, ownerID: UUID?) throws -> Bell {
    guard configuration?.isValid == true else { throw Failure.configuration }
    if let ownerID = ownerID, let existing = journal.records.first(where: { $0.ownerID == ownerID && !$0.retired }) {
      guard !existing.expired else { throw Failure.expired }; return existing.bell
    }
    let key = Curve25519.Signing.PrivateKey()
    let token = "bell_" + Self.url64(Data([2]) + (try Self.random(16)))
    let bell = Bell(id: UUID(), name: name, token: token, bellKey: key.rawRepresentation.base64EncodedString(),
                    contentSecret: try Self.random(32).base64EncodedString())
    var value = journal; value.records.append(Record(bell: bell, ownerID: ownerID)); try save(value)
    return bell
  }
  func bind(_ id: UUID, bellKey: String, apnsToken: Data?, level: Bell.ReceiveLevel) throws -> Bell.RelayBindingResponse {
    try change(id, key: bellKey) { $0.level = level; $0.ready = true }
    var response = Bell.RelayBindingResponse(bellID: id, endpointID: journal.deviceID.map { "device:" + $0 } ?? "pending", level: level)
    response.pending = true
    return response
  }
  func unbind(_ id: UUID, bellKey: String) throws {
    try change(id, key: bellKey) { $0.level = nil; $0.ready = true }
  }
  func deleteBell(_ id: UUID, bellKey: String) throws {
    // Retain management credentials until remote retirement is acknowledged.
    try change(id, key: bellKey, allowRetired: true) { $0.retired = true; $0.ready = true; $0.level = nil }
  }

  static func authorization(bell: Bell, method: String, path: String, body: Data, timestamp: Int64, nonce: Data) throws -> String {
    guard let seed = Data(base64Encoded: bell.bellKey) else { throw Failure.localCredentials }
    let proof = ["bellkey/v1", method, path, String(timestamp), nonce.base64EncodedString(), hex(Data(SHA256.hash(data: body)))].joined(separator: "\n")
    let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: Data(proof.utf8))
    return "Bell-Key bell_id=\(wireID(bell.id)), ts=\(timestamp), nonce=\(nonce.base64EncodedString()), sig=\(signature.base64EncodedString())"
  }

  private func request(_ method: String, _ path: String, json: [String: Any]? = nil, bell: Bell? = nil,
                       endpointKey: Bool = false, acceptMissing: Bool = false) async throws -> [String: Any] {
    guard let config = configuration, config.baseURL.scheme == "https" ||
      (config.baseURL.scheme == "http" && ["127.0.0.1", "localhost"].contains(config.baseURL.host ?? "")),
      config.baseURL.user == nil, config.baseURL.password == nil,
      config.baseURL.query == nil, config.baseURL.fragment == nil,
      config.baseURL.path.isEmpty || config.baseURL.path == "/" else { throw Failure.configuration }
    guard let url = URL(string: path, relativeTo: config.baseURL)?.absoluteURL else { throw Failure.configuration }
    let body = try json.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
    var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 10
    if json != nil { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let bell = bell {
      request.setValue(try Self.authorization(bell: bell, method: method, path: path, body: body,
        timestamp: Int64(Date().timeIntervalSince1970), nonce: Self.random(16)), forHTTPHeaderField: "Authorization")
    } else if let mint = journal.mintKey { request.setValue("Bearer " + mint, forHTTPHeaderField: "Authorization") }
    if endpointKey { request.setValue(journal.endpointKey, forHTTPHeaderField: "X-Endpoint-Key") }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, response.url?.host == config.baseURL.host,
          response.url?.scheme == config.baseURL.scheme, data.count <= 262144 else { throw Failure.invalidResponse }
    if acceptMissing && response.statusCode == 404 { return [:] }
    guard (200..<300).contains(response.statusCode) else { throw Failure.response(response.statusCode) }
    if data.isEmpty { return [:] }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
    return object
  }

  static func requireEnrollmentToken(_ token: String) throws -> String {
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw Failure.missingEnrollment }
    return value
  }

  func synchronize(apnsToken: Data?) async throws {
    guard !syncing else { syncAgain = true; return }
    syncing = true
    defer {
      syncing = false
      if syncAgain { syncAgain = false; kick() }
      else if hasPendingOperations { let delay = retryDelay; retryDelay = min(60, retryDelay * 2); kick(after: delay) }
      else { retryDelay = 2 }
    }
    do { try await synchronizeOperations(apnsToken: apnsToken) }
    catch {
      var value = journal
      for index in value.records.indices where value.records[index].pending && !value.records[index].expired {
        if value.records[index].operationError == nil { value.records[index].operationError = error.localizedDescription }
      }
      try save(value)
      lastError = error.localizedDescription
      throw error
    }
  }

  private func synchronizeOperations(apnsToken: Data?) async throws {
    guard let config = configuration, config.isValid else { throw Failure.configuration }
    if journal.mintKey == nil {
      let paidToken = try Self.requireEnrollmentToken(try await proofProvider.enrollmentProof())
      let response: [String: Any]
      do { response = try await request("POST", "/devices", json: ["paid_token": paidToken]) }
      catch Failure.response(let code) { throw Failure.enrollmentRejected(code) }
      guard let id = response["device_id"] as? String, let key = response["mint_key"] as? String else { throw Failure.invalidResponse }
      var value = journal; value.deviceID = id; value.mintKey = key; try save(value)
    }
    if let token = apnsToken, !token.isEmpty, let device = journal.deviceID {
      _ = try await request("PUT", "/devices/\(device)/endpoint", json: ["apns_token": Self.hex(token),
        "apns_env": config.environment, "apns_topic": config.topic], endpointKey: true)
    }
    var verdictError: Error?
    do { try await flushVerdicts() } catch { verdictError = error }
    // Each immutable operation snapshot is acknowledged only if its revision
    // is still desired after the await; a close/unbind wins over stale replies.
    var firstError: Error? = verdictError
    for record in journal.records where record.ready && record.pending && !record.expired {
      do {
        try await execute(record, apnsToken: apnsToken)
        guard let i = journal.records.firstIndex(where: { $0.bell.id == record.bell.id }),
              journal.records[i].revision == record.revision else { continue }
        var value = journal; value.records[i].pending = false; value.records[i].provisioned = !record.retired; value.records[i].operationError = nil
        try save(value)
      } catch Failure.response(let code) where code == 404 || code == 410 {
        var value = journal
        if let i = value.records.firstIndex(where: { $0.bell.id == record.bell.id }) { value.records[i].expired = true; value.records[i].pending = false; try save(value) }
      } catch {
        // Preserve this operation, but do not starve unrelated Bells.
        var value = journal
        if let i = value.records.firstIndex(where: { $0.bell.id == record.bell.id }), value.records[i].revision == record.revision {
          value.records[i].operationError = error.localizedDescription
          try save(value)
        }
        if firstError == nil { firstError = error }
      }
    }
    if let error = firstError { lastError = error.localizedDescription; throw error }
    lastError = nil
    // Keep unresolved Ask credentials. Remove only acknowledged retirement records.
    var compacted = journal
    let unresolved = Set((journal.submissions ?? []).filter { $0.status == "submitting" }.map { $0.bellID })
    let retired = Set(journal.records.filter { $0.retired && !$0.pending && !unresolved.contains($0.bell.id) }.map { $0.bell.id })
    compacted.records.removeAll { retired.contains($0.bell.id) }
    compacted.submissions?.removeAll { retired.contains($0.bellID) && $0.status != "submitting" }
    if !retired.isEmpty { try save(compacted) }
  }

  func submitVerdict(bellID: UUID, askID: String, verdict: String) async throws -> String {
    guard ["approve", "deny"].contains(verdict), let id = BellWireEnvelope.bytes(askID), id.count == 16,
          let record = journal.records.first(where: { $0.bell.id == bellID && !$0.retired }),
          let secret = record.bell.contentSecret, let key = Data(base64Encoded: secret) else { throw Failure.localCredentials }
    if journal.submissions?.contains(where: { $0.askID == askID && $0.bellID == bellID }) != true {
      let bytes = Data(("verdict" + "\0" + askID + "\0" + verdict).utf8)
      let mac = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: key)))
      var value = journal
      if value.submissions == nil { value.submissions = [] }
      value.submissions!.append(Submission(bellID: bellID, askID: askID, verdict: verdict, mac: Self.url64(mac)))
      try save(value)
    }
    do { try await flushVerdicts() } catch { kick(after: retryDelay); throw error }
    return journal.submissions?.first(where: { $0.askID == askID && $0.bellID == bellID })?.status ?? "retryable_failure"
  }

  private func flushVerdicts() async throws {
    var firstError: Error?
    for submission in journal.submissions ?? [] where submission.status == "submitting" {
      do {
        guard let record = journal.records.first(where: { $0.bell.id == submission.bellID }) else { throw Failure.missingRecord }
        let result = try await request("POST", "/bells/" + Self.wireID(submission.bellID) + "/asks/" + submission.askID + "/verdict",
          json: ["verdict": submission.verdict, "mac": submission.mac], bell: record.bell)
        guard let status = result["status"] as? String, ["accepted", "expired"].contains(status) else { throw Failure.invalidResponse }
        var value = journal
        guard let index = value.submissions?.firstIndex(where: { $0.askID == submission.askID && $0.bellID == submission.bellID }) else { continue }
        value.submissions![index].status = status == "accepted" && result["verdict"] as? String != submission.verdict ? "resolved_elsewhere" : status
        try save(value)
      } catch Failure.response(let code) where code == 404 || code == 410 {
        var value = journal
        if let index = value.submissions?.firstIndex(where: { $0.askID == submission.askID && $0.bellID == submission.bellID }) { value.submissions![index].status = "expired"; try save(value) }
      } catch { if firstError == nil { firstError = error } }
    }
    if let error = firstError { throw error }
  }

  private func execute(_ record: Record, apnsToken: Data?) async throws {
    let bell = record.bell; let id = Self.wireID(bell.id)
    if record.retired {
      _ = try await request("DELETE", "/bells/\(id)", bell: bell, acceptMissing: true); return
    }
    if !record.provisioned {
      guard let tokenBytes = BellWireEnvelope.bytes(String(bell.token.dropFirst(5))),
            let seed = Data(base64Encoded: bell.bellKey) else { throw Failure.localCredentials }
      let verifier = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString()
      _ = try await request("POST", "/bells", json: ["bell_id": id, "token_hash": Self.hex(Data(SHA256.hash(data: tokenBytes))),
        "verifier": verifier, "type": "plain", "policy": ["require_enc": true, "ask_allowed": true]])
    }
    guard let device = journal.deviceID else { throw Failure.missingDevice }
    if let level = record.level {
      guard let apnsToken = apnsToken, !apnsToken.isEmpty else { throw Failure.missingAPNsToken }
      _ = try await request("PUT", "/bells/\(id)/bindings/self", json: ["device_id": device, "level": level.rawValue], bell: bell, endpointKey: true)
    } else {
      _ = try await request("DELETE", "/bells/\(id)/bindings/device:\(device)", bell: bell, acceptMissing: true)
    }
  }

  func fetchState(since: [UUID: Int64]) async throws -> [(UUID, Bell.ReceivedState)] {
    // A refresh hint also attempts pending work, but operation failures do not
    // prevent independent state recovery.
    do { try await synchronize(apnsToken: endpoint) } catch { }
    let known = journal.records.filter { $0.ready && !$0.retired && !$0.expired }
    var result: [(UUID, Bell.ReceivedState)] = []
    for start in stride(from: 0, to: known.count, by: 200) {
      let chunk = Array(known[start..<min(start + 200, known.count)])
      let nonce = try Self.random(16); let timestamp = Int64(Date().timeIntervalSince1970)
      let entries: [[String: Any]] = try chunk.map { record in
        let id = Self.wireID(record.bell.id); let version = since[record.bell.id] ?? 0
        let text = ["bellkey/v1", "state", id, String(version), String(timestamp), nonce.base64EncodedString()].joined(separator: "\n")
        guard let seed = Data(base64Encoded: record.bell.bellKey) else { throw Failure.localCredentials }
        let sig = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: Data(text.utf8))
        return ["bell_id": id, "since": version, "sig": sig.base64EncodedString()]
      }
      let response = try await request("POST", "/state", json: ["ts": timestamp, "nonce": nonce.base64EncodedString(), "bells": entries])
      guard let states = response["states"] as? [[String: Any]], let errors = response["errors"] as? [[String: Any]] else { throw Failure.invalidResponse }
      for error in errors {
        guard error["error"] as? String == "not_found", let id = error["bell_id"] as? String,
              let index = journal.records.firstIndex(where: { Self.wireID($0.bell.id) == id && $0.provisioned }) else { continue }
        var value = journal; value.records[index].expired = true; value.records[index].pending = false; try save(value)
      }
      for var state in states {
        guard let id = state["bell_id"] as? String, let record = chunk.first(where: { Self.wireID($0.bell.id) == id }),
              journal.records.contains(where: { $0.bell.id == record.bell.id && !$0.retired }),
              let version = state["seq"] as? Int64 else { throw Failure.invalidResponse }
        state["v"] = 1; state["state_version"] = version
        let decoded = try BellWireEnvelope.decode(state, contentSecret: record.bell.contentSecret)
        if let status = decoded.status {
          var snapshot = Bell.ReceivedState(title: status.title, body: status.body,
            state: status.state.flatMap(Bell.WorkState.init(rawValue:)), progress: status.progress, updatedAt: Date())
          snapshot.stateVersion = version; result.append((record.bell.id, snapshot))
        }
      }
    }
    return result
  }
}


@MainActor struct UnavailableBellRelay: BellRelayOperations {
  let error: Error
  func operationStatus(for id: UUID) -> AnyPublisher<BellOperationStatus, Never> { Just(.retrying(error.localizedDescription)).eraseToAnyPublisher() }
  func createBell(name: String, ownerID: UUID?) throws -> Bell { throw error }
  func bind(_ id: UUID, bellKey: String, apnsToken: Data?, level: Bell.ReceiveLevel) throws -> Bell.RelayBindingResponse { throw error }
  func unbind(_ id: UUID, bellKey: String) throws { throw error }
  func deleteBell(_ id: UUID, bellKey: String) throws { throw error }
}
