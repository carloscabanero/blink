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

// Decode the Relay envelope from APNs userInfo. Currently mocked. Replace with the Relay codec before accepting real traffic.
struct BellMockPush: Decodable {
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

  static func decode(_ userInfo: [AnyHashable: Any]) -> BellMockPush? {
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
