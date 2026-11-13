import CryptoKit
import Foundation

final class FixtureProtocol: URLProtocol {
  static let lock = NSLock()
  static var paths: [String] = []
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
    if path == "/devices" { body = ["device_id": "00000000-0000-0000-0000-000000000001", "mint_key": "fixture-mint"] }
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

func require(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label) }
func hexData(_ hex: String) -> Data {
  let c = Array(hex)
  return Data(stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...$0+1]), radix: 16)! })
}
@main struct Tests {
  @MainActor static func main() async throws {
    let suite = "bell-config-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.setVolatileDomain(["BellRelayURL": "https://fixture.invalid", "BellAPNsEnvironment": "sandbox"], forName: UserDefaults.argumentDomain)
    require(LiveBellRelay.Configuration.configured(defaults: defaults, topic: "test.blink") != nil, "valid launch configuration")
    defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    require(defaults.persistentDomain(forName: suite)?["BellRelayURL"] as? String == "https://fixture.invalid", "configuration survives launch argument removal")
    defaults.set("https://fixture.invalid/unsafe-path", forKey: "BellRelayURL")
    require(LiveBellRelay.Configuration.configured(defaults: defaults, topic: "test.blink") == nil, "reject path-bearing configuration")
    defaults.set("https://fixture.invalid", forKey: "BellRelayURL")
    defaults.set("typo", forKey: "BellAPNsEnvironment")
    require(LiveBellRelay.Configuration.configured(defaults: defaults, topic: "test.blink") == nil, "reject invalid APNs environment")
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
    let config = LiveBellRelay.Configuration(baseURL: URL(string: "https://fixture.invalid")!, paidToken: "dev:test", topic: "test.blink", environment: "sandbox")
    let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [FixtureProtocol.self]
    let session = URLSession(configuration: sessionConfig)
    let owner = UUID()
    let relay = try LiveBellRelay(configuration: config, journalURL: url, session: session)
    let bell = try relay.createBell(name: "build", ownerID: owner)
    require(try! relay.createBell(name: "retry", ownerID: owner) == bell, "owner creation is stable")
    _ = try relay.bind(bell.id, bellKey: bell.bellKey, apnsToken: Data([1]), level: .loud)
    FixtureProtocol.failBind = true
    do { try await relay.synchronize(apnsToken: Data([1])); preconditionFailure("failed bind accepted") }
    catch LiveBellRelay.Failure.response(503) {}
    let restored = try LiveBellRelay(configuration: config, journalURL: url, session: session)
    require(try! restored.createBell(name: "restart", ownerID: owner) == bell, "lost reply/restart preserves identity and secrets")
    FixtureProtocol.failBind = false
    try await restored.synchronize(apnsToken: Data([2]))
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
    let retired = try LiveBellRelay(configuration: config, journalURL: url, session: session)
    FixtureProtocol.paths = []
    try await retired.synchronize(apnsToken: Data([3]))
    require(FixtureProtocol.paths.contains(where: { $0.hasPrefix("DELETE /bells/") && !$0.contains("/bindings/") }), "offline revocation survives restart")
    require(!FixtureProtocol.paths.contains("POST /bells"), "retirement never recreates")
    let isolated = try LiveBellRelay(configuration: config, journalURL: directory.appendingPathComponent("isolation.json"), session: session)
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
    let restarted = try LiveBellRelay(configuration: config, journalURL: directory.appendingPathComponent("isolation.json"), session: session)
    require(restarted.hasPendingOperations, "Ask submission survives restart")
    FixtureProtocol.failVerdict = false
    FixtureProtocol.verdictResult = "deny"
    let outcome = try await restarted.submitVerdict(bellID: good.id, askID: askID, verdict: "deny")
    require(outcome == "resolved_elsewhere", "original saved choice not overwritten and competing result is truthful")
    require(!restarted.hasPendingOperations, "resolved Ask is not retried")
    FixtureProtocol.verdictStatus = "expired"
    let expired = try await restarted.submitVerdict(bellID: good.id, askID: LiveBellRelay.url64(Data(repeating: 9,count:16)), verdict: "approve")
    require(expired == "expired", "expired Ask remains expired")
    print("22 live transport/configuration/recovery/Ask checks passed")
  }
}
