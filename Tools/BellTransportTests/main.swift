import Combine
import CryptoKit
import Foundation

final class FixtureProtocol: URLProtocol {
  static let lock = NSLock()
  static var paths: [String] = []
  static var enrollmentStatus = 200
  static var enrollmentToken: String?
  static var failBind = false
  static var failVerdict = false
  static var verdictResult = "approve"
  static var verdictStatus = "accepted"
  static var failedBindingID: String?
  static var state: [String: Any]?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    let path = request.url!.path
    Self.paths.append(request.httpMethod! + " " + path)
    var status = 200
    var body: [String: Any] = [:]
    if path == "/devices" {
      status = Self.enrollmentStatus
      let data = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return data
      } ?? Data()
      Self.enrollmentToken = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["paid_token"] as? String
      body = ["device_id": "00000000-0000-0000-0000-000000000001", "mint_key": "fixture-mint"] }
    if path.hasSuffix("/bindings/self") && (Self.failBind || Self.failedBindingID.map { path.contains($0) } == true) { status = 503 }
    if path.hasSuffix("/verdict") {
      if Self.failVerdict { status = 503 }
      else { body = ["status": Self.verdictStatus, "verdict": Self.verdictResult] }
    }
    if path == "/state" { body = ["states": Self.state.map { [$0] } ?? [], "errors": []] }
    Self.lock.unlock()
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

var checks = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); checks += 1 }
func hexData(_ hex: String) -> Data {
  let c = Array(hex)
  return Data(stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...$0+1]), radix: 16)! })
}
@MainActor final class FixturePurchaseProof: BellPurchaseProofProvider {
  var value = "dev:test"
  var calls = 0
  func enrollmentProof() async throws -> String { calls += 1; return value }
}

@main struct Tests {
  @MainActor static func main() async throws {
    require(LiveBellRelay.Configuration(baseURL: URL(string: "https://fixture.invalid")!, topic: "test", environment: "sandbox").isValid, "valid configuration")
    require(!LiveBellRelay.Configuration(baseURL: URL(string: "https://fixture.invalid/unsafe")!, topic: "test", environment: "sandbox").isValid, "reject path-bearing configuration")
    require(!LiveBellRelay.Configuration(baseURL: URL(string: "https://fixture.invalid")!, topic: "test", environment: "typo").isValid, "reject invalid APNs environment")
    let proofProvider = FixturePurchaseProof()
    let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    let proof = (vectors["key_proofs"] as! [[String: Any]])[0]
    let proofBell = Bell(id: BellWireEnvelope.uuid(proof["bell_id_hex"] as! String)!, name: "vector", token: "", bellKey: hexData(proof["bell_key_seed_hex"] as! String).base64EncodedString(), contentSecret: nil)
    let auth = try LiveBellRelay.authorization(bell: proofBell, method: proof["method"] as! String,
      path: proof["request_uri"] as! String, body: Data((proof["body"] as! String).utf8),
      timestamp: proof["ts"] as! Int64, nonce: hexData(proof["nonce_hex"] as! String))
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: proof["verifier"] as! String)!)
    let signatureText = auth.components(separatedBy: ", sig=").last!
    let signedData = Data((proof["proof_string"] as! String).utf8)
    require(publicKey.isValidSignature(Data(base64Encoded: signatureText)!, for: signedData), "Swift signature verifies over Go proof bytes")
    require(publicKey.isValidSignature(hexData(proof["sig_hex"] as! String), for: signedData), "Go signature verifies with CryptoKit")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bell-transport-" + UUID().uuidString)
    let url = directory.appendingPathComponent("journal.json")
    let config = LiveBellRelay.Configuration(baseURL: URL(string: "https://fixture.invalid")!, topic: "test.blink", environment: "sandbox")
    let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [FixtureProtocol.self]
    let session = URLSession(configuration: sessionConfig)
    let owner = UUID()
    let relay = try LiveBellRelay(configuration: config, proofProvider: proofProvider, journalURL: url, session: session)
    let bell = try relay.createBell(name: "build", ownerID: owner)
    require(try! relay.createBell(name: "retry", ownerID: owner) == bell, "owner creation is stable")
    _ = try relay.bind(bell.id, bellKey: bell.bellKey, apnsToken: Data([1]), level: .loud)
    var observed: [BellOperationStatus] = []
    let observation = relay.operationStatus(for: bell.id).sink { observed.append($0) }
    require(observed.last == .pending, "binding exposes local pending, not success")
    FixtureProtocol.failBind = true
    do { try await relay.synchronize(apnsToken: Data([1])); preconditionFailure("failed bind accepted") }
    catch LiveBellRelay.Failure.response(503) {}
    require(observed.last == .retrying(LiveBellRelay.Failure.response(503).localizedDescription), "failed bind publishes useful retry reason")
    withExtendedLifetime(observation) {}
    let restored = try LiveBellRelay(configuration: config, proofProvider: proofProvider, journalURL: url, session: session)
    require(try! restored.createBell(name: "restart", ownerID: owner) == bell, "lost reply/restart preserves identity and secrets")
    FixtureProtocol.failBind = false
    try await restored.synchronize(apnsToken: Data([2]))
    var restoredStatus: BellOperationStatus?
    let restoredObservation = restored.operationStatus(for: bell.id).sink { restoredStatus = $0 }
    require(restoredStatus == .confirmed, "only acknowledged bind is confirmed after restart")
    withExtendedLifetime(restoredObservation) {}
    let createCount = FixtureProtocol.paths.filter { $0 == "POST /bells" }.count
    require(createCount == 2, "retry same create after ambiguous completion")
    FixtureProtocol.paths = []
    try await restored.synchronize(apnsToken: Data([3]))
    require(!FixtureProtocol.paths.contains(where: { $0.hasSuffix("/bindings/self") }), "token rotation does not rebind")
    require(FixtureProtocol.paths.contains(where: { $0.contains("/endpoint") }), "token rotation updates endpoint")
    let messageID = Data(repeating: 5, count: 16)
    let timestamp: Int64 = 1790000000
    var aad = Data("blinkbell/v1".utf8); var id = bell.id.uuid
    withUnsafeBytes(of: &id) { aad.append(contentsOf: $0) }; aad.append(messageID)
    var ts = timestamp.bigEndian; withUnsafeBytes(of: &ts) { aad.append(contentsOf: $0) }
    let ciphertext = try ChaChaPoly.seal(Data("{\"title\":\"done\"}".utf8), using: SymmetricKey(data: Data(base64Encoded: bell.contentSecret!)!), authenticating: aad).combined
    FixtureProtocol.state = ["bell_id": LiveBellRelay.wireID(bell.id), "seq": 9, "state": "ok", "progress": 100,
                            "enc": true, "ct": LiveBellRelay.url64(ciphertext), "id": LiveBellRelay.url64(messageID), "ts": timestamp]
    let states = try await restored.fetchState(since: [:])
    require(states.count == 1 && states[0].1.title == "done" && states[0].1.stateVersion == 9, "encrypted snapshot decoded with version")
    try restored.unbind(bell.id, bellKey: bell.bellKey)
    try await restored.synchronize(apnsToken: Data([3]))
    require(FixtureProtocol.paths.contains(where: { $0.contains("DELETE /bells/") && $0.contains("/bindings/device:") }), "durable unbind")
    try restored.deleteBell(bell.id, bellKey: bell.bellKey)
    let retired = try LiveBellRelay(configuration: config, proofProvider: proofProvider, journalURL: url, session: session)
    FixtureProtocol.paths = []
    try await retired.synchronize(apnsToken: Data([3]))
    require(FixtureProtocol.paths.contains(where: { $0.hasPrefix("DELETE /bells/") && !$0.contains("/bindings/") }), "offline revocation survives restart")
    require(!FixtureProtocol.paths.contains("POST /bells"), "retirement never recreates")
    let isolated = try LiveBellRelay(configuration: config, proofProvider: proofProvider, journalURL: directory.appendingPathComponent("isolation.json"), session: session)
    let bad = try isolated.createBell(name: "unavailable", ownerID: UUID())
    let good = try isolated.createBell(name: "independent", ownerID: UUID())
    _ = try isolated.bind(bad.id, bellKey: bad.bellKey, apnsToken: Data([1]), level: .loud)
    _ = try isolated.bind(good.id, bellKey: good.bellKey, apnsToken: Data([1]), level: .loud)
    FixtureProtocol.failedBindingID = LiveBellRelay.wireID(bad.id)
    FixtureProtocol.paths = []
    do { try await isolated.synchronize(apnsToken: Data([1])); preconditionFailure("failed operation accepted") }
    catch LiveBellRelay.Failure.response(503) {}
    require(FixtureProtocol.paths.contains("PUT /bells/" + LiveBellRelay.wireID(good.id) + "/bindings/self"), "failed Bell does not starve independent Bell")
    require(isolated.hasPendingOperations, "failed operation remains pending")
    FixtureProtocol.failedBindingID = nil
    try await isolated.synchronize(apnsToken: Data([1]))
    require(!isolated.hasPendingOperations, "pending operation recovers")
    let askID = LiveBellRelay.url64(Data(repeating: 8, count: 16))
    FixtureProtocol.failVerdict = true
    do { _ = try await isolated.submitVerdict(bellID: good.id, askID: askID, verdict: "approve"); preconditionFailure("failed verdict accepted") }
    catch LiveBellRelay.Failure.response(503) {}
    let restarted = try LiveBellRelay(configuration: config, proofProvider: proofProvider, journalURL: directory.appendingPathComponent("isolation.json"), session: session)
    require(restarted.hasPendingOperations, "Ask submission survives restart")
    FixtureProtocol.failVerdict = false
    FixtureProtocol.verdictResult = "deny"
    let outcome = try await restarted.submitVerdict(bellID: good.id, askID: askID, verdict: "deny")
    require(outcome == "resolved_elsewhere", "original saved choice not overwritten and competing result is truthful")
    require(!restarted.hasPendingOperations, "resolved Ask is not retried")
    FixtureProtocol.verdictStatus = "expired"
    let expired = try await restarted.submitVerdict(bellID: good.id, askID: LiveBellRelay.url64(Data(repeating: 9,count:16)), verdict: "approve")
    require(expired == "expired", "expired Ask remains expired")
    // Distinguish a missing local input from a server rejection and from APNs registration.
    do { _ = try LiveBellRelay.requireEnrollmentToken(" \n"); preconditionFailure("blank enrollment accepted") }
    catch LiveBellRelay.Failure.missingEnrollment {}
    require(try! LiveBellRelay.requireEnrollmentToken(" dev:carlos ") == "dev:carlos", "trim enrollment input")
    let diagnostic = try LiveBellRelay(configuration: config, proofProvider: proofProvider, journalURL: directory.appendingPathComponent("diagnostic.json"), session: session)
    let diagnosticBell = try diagnostic.createBell(name: "diagnostic", ownerID: UUID())
    _ = try diagnostic.bind(diagnosticBell.id, bellKey: diagnosticBell.bellKey, apnsToken: nil, level: .loud)
    FixtureProtocol.enrollmentStatus = 401
    do { try await diagnostic.synchronize(apnsToken: nil); preconditionFailure("rejected enrollment accepted") }
    catch LiveBellRelay.Failure.enrollmentRejected(401) {}
    require(FixtureProtocol.enrollmentToken == "dev:test", "explicit test token reaches enrollment HTTP body")
    FixtureProtocol.enrollmentStatus = 200
    FixtureProtocol.paths = []
    do { try await diagnostic.synchronize(apnsToken: nil); preconditionFailure("binding without APNs accepted") }
    catch LiveBellRelay.Failure.missingAPNsToken {}
    require(diagnostic.hasPendingOperations && !FixtureProtocol.paths.contains(where: { $0.hasSuffix("/bindings/self") }), "missing APNs preserves pending binding without sending it")
    FixtureProtocol.paths = []
    do { try await diagnostic.synchronize(apnsToken: Data()); preconditionFailure("empty APNs accepted") }
    catch LiveBellRelay.Failure.missingAPNsToken {}
    require(!FixtureProtocol.paths.contains(where: { $0.hasSuffix("/endpoint") }), "empty APNs is not registered")
    try await diagnostic.synchronize(apnsToken: Data([4]))
    require(!diagnostic.hasPendingOperations && !FixtureProtocol.paths.contains("POST /devices"), "APNs arrival completes binding without reenrollment")
    let lazyProof = FixturePurchaseProof()
    lazyProof.value = ""
    let lazy = try LiveBellRelay(configuration: config, proofProvider: lazyProof, journalURL: directory.appendingPathComponent("lazy.json"), session: session)
    let lazyBell = try lazy.createBell(name: "late purchase", ownerID: nil)
    _ = try lazy.bind(lazyBell.id, bellKey: lazyBell.bellKey, apnsToken: nil, level: .loud)
    require(lazyProof.calls == 0, "startup does not snapshot purchase")
    do { try await lazy.synchronize(apnsToken: Data([1])); preconditionFailure("empty purchase accepted") } catch LiveBellRelay.Failure.missingEnrollment {}
    lazyProof.value = "dev:late"
    try await lazy.synchronize(apnsToken: Data([1]))
    require(lazyProof.calls == 2 && !lazy.hasPendingOperations, "late purchase is requested again and recovers")
    let compacted = try JSONDecoder().decode(LiveBellRelay.Journal.self, from: Data(contentsOf: url))
    require(compacted.records.isEmpty, "acknowledged retirement compacted")
    let scheduledProof = FixturePurchaseProof()
    let scheduled = try LiveBellRelay(configuration: config, proofProvider: scheduledProof, journalURL: directory.appendingPathComponent("scheduler.json"), session: session)
    let scheduledBell = try scheduled.createBell(name: "foreground", ownerID: nil)
    _ = try scheduled.bind(scheduledBell.id, bellKey: scheduledBell.bellKey, apnsToken: nil, level: .loud)
    scheduled.updateEndpoint(Data([7]))
    require(scheduledProof.calls == 0 && scheduled.hasPendingOperations, "inactive Relay retains work without starting requests")
    FixtureProtocol.paths = []
    scheduled.setActive(true)
    let deadline = Date().addingTimeInterval(3)
    while scheduled.hasPendingOperations && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    require(!scheduled.hasPendingOperations, "activation drains queue without Tower refresh")
    scheduled.setActive(false)
    require(!FixtureProtocol.paths.contains("POST /state"), "scheduler does not require state refresh")
    print("\(checks) live transport/configuration/recovery/Ask checks passed")
  }
}
