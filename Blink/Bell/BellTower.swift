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

import Combine
import Foundation
import UIKit
import UserNotifications

@MainActor final class BellTower {
  static let shared = BellTower()

  private let relay: MockBellRelay
  private(set) var apnsToken: Data?
  private var snapshots: [Bell.ID: CurrentValueSubject<Bell.ReceivedState?, Never>] = [:]
  private let bindingStore: BellBindingStore
  private var activationObservation: AnyCancellable?

  init(relay: MockBellRelay = MockBellRelay(), bindingStore: BellBindingStore = BellBindingStore()) {
    self.relay = relay
    self.bindingStore = bindingStore
  }

  // MARK: Lifecycle and endpoint

  func start() {
    guard activationObservation == nil else { return }
    activationObservation = NotificationCenter.default
      .publisher(for: UIApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          await self?.refreshState()
        }
      }
    if UIApplication.shared.applicationState == .active {
      Task { await refreshState() }
    }
  }

  @discardableResult
  func refreshState(for bellID: Bell.ID? = nil) async -> ReceiveResult {
    // Retrieves state. Never replay Rings from a fetch.
    // [dev] TODO: Relay status retrieval. Prefer a device batch for activation; This is per-bell,
    // until we can work with devices on the relay. It also retain reads for known unbound Bells.
    let scope = bellID == nil ? "known Bells" : "one Bell"
    Zuse.logger(.machine, "Bell").info("Status refresh requested for \(scope) (Relay fetch deferred)")
    return .ignored
  }

  func updateAPNsToken(_ token: Data) {
    guard apnsToken != token else { return }
    let changed = apnsToken != nil
    apnsToken = token
    Zuse.logger(.machine, "Bell").info(changed ? "APNs endpoint changed" : "APNs endpoint received")
    Zuse.logger(.machine, "Bell").info("CLI push: APNS_DEVICE_TOKEN='\(token.map { String(format: "%02x", $0) }.joined())'")
    // [dev] TODO: rebind each Bell OR registerDevice
  }

  #if false
  // [dev] TODO PROPOSED RELAY API: unsupported today; deliberately unused.
  func registerDevice(apnsToken: Data) async throws {
    try await relay.registerDevice(deviceID: deviceID, apnsToken: apnsToken)
  }
  #endif

  // MARK: Create and bind

  func createBell(name: String) throws -> Bell {
    try relay.createBell(name: name)
  }

  @discardableResult
  func bind(_ bellID: Bell.ID, bellKey: String, contentSecret: String?,
            workURL: URL, level: Bell.ReceiveLevel) throws -> Bell.RelayBindingResponse {
    guard WorkURL.recognizes(workURL) else { throw BellError.invalidWorkURL }
    try attach(bellID, toWorkURL: workURL, contentSecret: contentSecret, level: level)
    do {
      return try relay.bind(bellID, bellKey: bellKey, apnsToken: apnsToken, level: level)
    } catch {
      // A bind can be re-entrant and executed again by the user
      do {
        try bindingStore.remove(bellID)
      } catch {
        Zuse.logger(.machine, "Bell").error("Could not remove attachment after failed binding: \(error.localizedDescription)")
      }
      throw error
    }
  }

  func localBinding(for bellID: Bell.ID) throws -> Bell.LocalBinding? { try bindingStore.binding(for: bellID) }

  func unbind(_ bellID: Bell.ID, bellKey: String) throws {
    try relay.unbind(bellID, bellKey: bellKey)
    try bindingStore.remove(bellID)
  }

  func retireBell(_ bellID: Bell.ID, bellKey: String) throws {
    let subject = snapshots.removeValue(forKey: bellID)
    subject?.send(nil)
    subject?.send(completion: .finished)
    try bindingStore.remove(bellID)

    try bindingStore.removeState(for: bellID)

    // Local retirement is authoritative. Relay deletion is a courtesy, with no retry.
    do { try relay.deleteBell(bellID, bellKey: bellKey) }
    catch { Zuse.logger(.machine, "Bell").error("Could not notify Relay of Bell retirement: \(error.localizedDescription)") }
  }

  // MARK: Local work association

  private func attach(_ bellID: Bell.ID, toWorkURL url: URL, contentSecret: String?,
                      level: Bell.ReceiveLevel) throws {
    try bindingStore.save(Bell.LocalBinding(contentSecret: contentSecret, workURL: url, acceptsPlaintext: contentSecret == nil, level: level), for: bellID)
  }

  func workURL(for bellID: Bell.ID) throws -> URL? {
    return try bindingStore.binding(for: bellID)?.workURL
  }

  // MARK: State and receipt

  enum ReceiveResult: Equatable { case ignored, updated }

  func state(_ bellID: Bell.ID) -> Bell.ReceivedState? { snapshot(bellID).value }

  func observe(_ bellID: Bell.ID) -> AnyPublisher<Bell.ReceivedState?, Never> {
    snapshot(bellID).eraseToAnyPublisher()
  }

  @discardableResult
  func receiveNotificationStatus(_ message: Bell.Message) throws -> ReceiveResult {
    guard let status = message.status else { return .ignored }
    guard let binding = try bindingStore.binding(for: message.bellID), binding.acceptsPlaintext else { return .ignored }
    return try applyStatus(status, for: message.bellID)
  }

  @discardableResult
  private func applyStatus(_ status: Bell.ReceivedState, for bellID: Bell.ID) throws -> ReceiveResult {
    let previous = state(bellID)
    if let incoming = status.stateVersion, let stored = previous?.stateVersion, incoming <= stored { return .ignored }
    guard previous?.stateVersion != status.stateVersion || previous?.title != status.title || previous?.body != status.body ||
          previous?.state != status.state || previous?.progress != status.progress || previous == nil else {
      return .ignored
    }
    try bindingStore.saveState(status, for: bellID)
    snapshot(bellID).send(status)
    return .updated
  }

  func requestNotificationPermission() async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
  }

  private func snapshot(_ bellID: Bell.ID) -> CurrentValueSubject<Bell.ReceivedState?, Never> {
    if let existing = snapshots[bellID] { return existing }
    // Relay versions and last-known snapshots survive app restarts.
    let subject = CurrentValueSubject<Bell.ReceivedState?, Never>(try? bindingStore.state(for: bellID))
    snapshots[bellID] = subject
    return subject
  }
}
