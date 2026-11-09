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

struct BellBindingStore {
  private let directoryURL: URL?

  init(directoryURL: URL? = nil) {
    self.directoryURL = directoryURL
  }

  private func directory() throws -> URL {
    if let directoryURL = directoryURL { return directoryURL }
    guard let group = Bundle.main.object(forInfoDictionaryKey: "BLINK_BELL_APP_GROUP") as? String,
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw CocoaError(.fileReadNoPermission)
    }
    return container.appendingPathComponent("Library/Application Support/Bell/Lookup", isDirectory: true)
  }

  func binding(for bellID: Bell.ID) throws -> Bell.LocalBinding? {
    let url = try directory().appendingPathComponent(bellID.uuidString + ".json")
    do { return try JSONDecoder().decode(Bell.LocalBinding.self, from: Data(contentsOf: url)) }
    catch CocoaError.fileReadNoSuchFile { return nil }
  }

  #if !BELL_NOTIFICATION_EXTENSION
  func save(_ binding: Bell.LocalBinding, for bellID: Bell.ID) throws {
    let directory = try directory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var url = directory.appendingPathComponent(bellID.uuidString + ".json")
    try JSONEncoder().encode(binding).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  func remove(_ bellID: Bell.ID) throws {
    let url = try directory().appendingPathComponent(bellID.uuidString + ".json")
    do { try FileManager.default.removeItem(at: url) }
    catch CocoaError.fileNoSuchFile { }
  }
  #endif

  // [dev] TODO: NSE status-cache writes need ordering; deferred.
}
