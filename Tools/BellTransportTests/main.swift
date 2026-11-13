import CryptoKit
import Foundation

final class FixtureProtocol: URLProtocol {
  static let lock = NSLock()
  static var paths: [String] = []
  static var failBind = false
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
    if path.hasSuffix("/bindings/self") && Self.failBind { status = 503 }
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
    print("11 live transport/recovery checks passed, including signed Go vector and encrypted state")
  }
}
