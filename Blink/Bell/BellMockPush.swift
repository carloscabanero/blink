//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

import Foundation
import CryptoKit

// Decode the Relay envelope from APNs userInfo. Currently mocked. Replace with the Relay codec before accepting real traffic.
struct BellMockPush: Decodable {
  var stateVersion: Int64? = nil
  var preparedTitle: String? = nil
  var preparedBody: String? = nil
  let mock: Bool
  let bellID: UUID
  let messageID: UUID?
  let status: Status?

  struct Status: Decodable {
    let title: String?
    let body: String?
    let state: String?
    let progress: Int?
  }

  private enum CodingKeys: String, CodingKey {
    case mock, status
    case bellID = "bell_id"
    case messageID = "message_id"
  }

  static func decode(_ userInfo: [AnyHashable: Any], contentSecret: String? = nil) -> BellMockPush? {
    if let envelope = userInfo["bell"] as? [String: Any], envelope["v"] != nil {
      return try? BellWireEnvelope.decode(envelope, contentSecret: contentSecret)
    }
    guard let envelope = userInfo["bell"] as? [String: Any],
          let data = try? JSONSerialization.data(withJSONObject: envelope),
          let push = try? JSONDecoder().decode(Self.self, from: data), push.mock else { return nil }
    if let status = push.status {
      guard push.messageID != nil,
            status.progress.map({ (0...100).contains($0) }) ?? true,
            status.state.map({ ["idle", "busy", "ok", "warn", "error", "attention"].contains($0) }) ?? true else {
        return nil
      }
    }
    return push
  }
}


// Production Relay v1 codec. Mock JSON never participates in this branch.
// Keep byte encodings aligned with bellproto and its shared golden vectors.
enum BellWireEnvelope {
  static func bytes(_ text: String) -> Data? {
    let raw = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4))
  }

  static func uuid(_ hex: String) -> UUID? {
    guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
    let c = Array(hex)
    let value = [String(c[0..<8]), String(c[8..<12]), String(c[12..<16]), String(c[16..<20]), String(c[20..<32])].joined(separator: "-")
    return UUID(uuidString: value)
  }

  static func bellID(_ userInfo: [AnyHashable: Any]) -> UUID? {
    guard let e = userInfo["bell"] as? [String: Any], let id = e["bell_id"] as? String else { return nil }
    return uuid(id)
  }

  enum Invalid: Error { case envelope }

  static func decode(_ e: [String: Any], contentSecret: String?) throws -> BellMockPush {
    guard e["v"] as? Int == 1, e["mock"] == nil,
          let hex = e["bell_id"] as? String, let bellID = uuid(hex),
          let id = e["id"] as? String, let idBytes = bytes(id), idBytes.count == 16,
          let messageID = uuid(idBytes.map { String(format: "%02x", $0) }.joined()),
          let ts = e["ts"] as? Int64, ts > 0 else { throw Invalid.envelope }
    let state = e["state"] as? String
    let progress = e["progress"] as? Int
    guard state.map({ ["idle", "busy", "ok", "warn", "error", "attention"].contains($0) }) ?? true,
          progress.map({ (0...100).contains($0) }) ?? true else { throw Invalid.envelope }
    var readable = e
    if e["enc"] as? Bool == true {
      guard let secret = contentSecret, let key = bytes(secret), key.count == 32,
            let ct = e["ct"] as? String, let sealed = bytes(ct) else { throw Invalid.envelope }
      var aad = Data("blinkbell/v1".utf8)
      var bellBytes = bellID.uuid
      withUnsafeBytes(of: &bellBytes) { aad.append(contentsOf: $0) }
      aad.append(idBytes)
      var timestamp = ts.bigEndian
      withUnsafeBytes(of: &timestamp) { aad.append(contentsOf: $0) }
      let clear = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: SymmetricKey(data: key), authenticating: aad)
      guard let fields = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else { throw Invalid.envelope }
      readable = fields
    }
    let title = readable["title"] as? String
    let body = readable["body"] as? String
    let status: BellMockPush.Status? = state != nil || progress != nil
      ? .init(title: title, body: body, state: state, progress: progress) : nil
    var result = BellMockPush(mock: false, bellID: bellID, messageID: messageID, status: status)
    result.stateVersion = e["state_version"] as? Int64
    result.preparedTitle = title
    result.preparedBody = body
    return result
  }
}
