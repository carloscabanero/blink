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
import UserNotifications

// Terminal-owned data, stored as a field of TermSessionPayload.
struct Bell: Codable, Equatable {
  typealias ID = UUID
  let id: ID
  let name: String
  let token: String          // SEND; only this value is offered for copying
  let bellKey: String        // MANAGE; owner supplies it for relay changes
  let contentSecret: String? // READ; nil for the plaintext prototype

  enum ReceiveLevel: String, Codable { case silent, loud }

  struct LocalBinding: Codable {
    var contentSecret: String? = nil
    let workURL: URL
    let acceptsPlaintext: Bool
    let level: ReceiveLevel? // nil only in older prototype records
    // [dev] TODO: encrypted Bells will need access to the Bell's content secret.
  }

  struct RelayBindingResponse: Equatable {
    let bellID: ID
    let endpointID: String
    let level: ReceiveLevel
  }

  enum WorkState: String, Codable { case idle, busy, ok, warn, error, attention }
  // Represent the incoming Bell event inside Blink. Combines the envelope with prepared UNNotificationContent from NSE.
  // APNs envelop -> BellPush -> Message -> optional ReceivedState
  struct Message {
    let id: UUID
    let bellID: ID
    let ring: Bool
    let title: String?
    let body: String?
    let status: ReceivedState?
    // [dev] TODO: Relay validation/decryption, state_version, ordering, dedupe and Ask.
  }

  // Latest work status that Tower stores and publishes to observers
  // State and Message are kept separate because State could be updated without a Ring.
  // Ie. "Progress update, 40%" -> Ring "Check this terminal" (still can keep state as 40%)
  // [dev] TODO Check without the Mock, this may be overdone.
  struct ReceivedState: Equatable, Codable {
    var stateVersion: Int64? = nil
    let title: String?
    let body: String?
    let state: WorkState?
    let progress: Int?
    let updatedAt: Date // local receipt time, not a Relay revision
  }
}

extension Bell.Message {
  init?(notificationContent content: UNNotificationContent) {
    guard let push = BellMockPush.decode(content.userInfo), let id = push.messageID else { return nil }
    // Alert text comes from the content prepared by iOS/NSE, independently of work status.
    self.init(id: id, bellID: push.bellID, ring: true,
              title: content.title, body: content.body, status: push.status.map {
      var state = Bell.ReceivedState(title: $0.title, body: $0.body,
                         state: $0.state.flatMap(Bell.WorkState.init(rawValue:)),
                         progress: $0.progress, updatedAt: Date())
      state.stateVersion = push.stateVersion
      return state
    })
  }
}

enum BellError: LocalizedError {
  case missingPayload, missingBell, invalidBellKey, invalidWorkURL

  var errorDescription: String? {
    switch self {
    case .missingPayload: return "This terminal is not ready yet."
    case .missingBell: return "Create a Bell for this terminal first."
    case .invalidBellKey: return "The Bell management key was not accepted."
    case .invalidWorkURL: return "A Bell binding needs a supported Work URL."
    }
  }
}
