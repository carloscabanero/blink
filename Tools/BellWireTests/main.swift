import Foundation

func require(_ condition: @autoclosure () -> Bool, _ label: String) {
  precondition(condition(), label)
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let vectors = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let vector = (vectors["envelope"] as! [[String: Any]])[0]
func hexData(_ hex: String) -> Data {
  let c = Array(hex)
  return Data(stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...$0+1]), radix: 16)! })
}
func url64(_ data: Data) -> String {
  data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
var envelope: [String: Any] = [
  "v": 1, "bell_id": vector["bell_id_hex"]!, "id": url64(hexData(vector["message_id_hex"] as! String)),
  "ts": vector["ts"]!, "enc": true, "ct": vector["ct"]!, "state": "ok", "progress": 100
]
let secret = hexData(vector["content_secret_hex"] as! String).base64EncodedString()
let decoded = try BellWireEnvelope.decode(envelope, contentSecret: secret)
require(decoded.preparedTitle == "make · exit 0", "Go/Swift decryption vector")
require(decoded.preparedBody == "11m32s on build-01", "decrypted body")
require(decoded.status?.progress == 100, "status")
require(BellMockPush.decode(["bell": envelope]) == nil, "missing key fails closed")
require(BellMockPush.decode(["bell": envelope], contentSecret: Data(repeating: 0, count: 32).base64EncodedString()) == nil, "wrong key fails closed")
var changed = envelope
changed["ts"] = (vector["ts"] as! Int64) + 1
require(BellMockPush.decode(["bell": changed], contentSecret: secret) == nil, "AAD timestamp authentication")
changed = envelope; changed["bell_id"] = String(repeating: "0", count: 32)
require(BellMockPush.decode(["bell": changed], contentSecret: secret) == nil, "AAD destination authentication")
changed = envelope; changed["v"] = 2
require(BellMockPush.decode(["bell": changed], contentSecret: secret) == nil, "unknown version")
changed = envelope; changed["progress"] = 101
require(BellMockPush.decode(["bell": changed], contentSecret: secret) == nil, "invalid progress")
envelope["enc"] = false; envelope.removeValue(forKey: "ct"); envelope["title"] = "plaintext"
require(BellMockPush.decode(["bell": envelope])?.preparedTitle == "plaintext", "plaintext wire")
envelope.removeValue(forKey: "state"); envelope.removeValue(forKey: "progress")
require(BellMockPush.decode(["bell": envelope])?.status == nil, "Ring-only has no state effect")
print("10 Relay codec checks passed (including Go/Swift encrypted golden vector)")
