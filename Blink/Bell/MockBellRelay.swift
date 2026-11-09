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

// Mock server records persist independently of Terminal payloads and Tower state.
// [dev] TODO: replace with the Relay client; no owner-side registration or restoration.
struct MockBellRelay {
  private let endpointID: String
  private let directoryURL: URL?

  init(endpointID: String = "mock-local-endpoint", directoryURL: URL? = nil) {
    self.endpointID = endpointID
    self.directoryURL = directoryURL
  }

  func createBell(name: String) throws -> Bell {
    let id = UUID()
    let key = "mock-manage.\(UUID().uuidString)"
    let url = try keyURL(for: id)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(key.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return Bell(id: id, name: name, token: "mock-bell.\(id.uuidString)", bellKey: key, contentSecret: nil)
  }

  func bind(_ bellID: Bell.ID, bellKey: String, apnsToken: Data?, level: Bell.ReceiveLevel) throws -> Bell.RelayBindingResponse {
    try authorize(bellID, bellKey: bellKey)
    // The mock accepts an absent APNs token; it does not enroll an actual endpoint.
    return Bell.RelayBindingResponse(bellID: bellID, endpointID: endpointID, level: level)
  }

  func unbind(_ bellID: Bell.ID, bellKey: String) throws {
    try authorize(bellID, bellKey: bellKey)
  }

  func deleteBell(_ bellID: Bell.ID, bellKey: String) throws {
    guard let key = try storedKey(for: bellID) else { return }
    guard key == bellKey else { throw BellError.invalidBellKey }
    try FileManager.default.removeItem(at: keyURL(for: bellID))
  }

  private func authorize(_ bellID: Bell.ID, bellKey: String) throws {
    guard let key = try storedKey(for: bellID) else { throw BellError.missingBell }
    guard key == bellKey else { throw BellError.invalidBellKey }
  }

  private func storedKey(for bellID: Bell.ID) throws -> String? {
    do { return try String(contentsOf: keyURL(for: bellID), encoding: .utf8) }
    catch CocoaError.fileReadNoSuchFile { return nil }
  }

  private func keyURL(for bellID: Bell.ID) throws -> URL {
    let directory = try directoryURL ?? FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("Bell/MockRelay", isDirectory: true)
    return directory.appendingPathComponent(bellID.uuidString)
  }
}
