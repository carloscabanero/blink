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
  static let shared: BellTower = {
    do { return BellTower(relay: try LiveBellRelay(configuration: .configured())) }
    catch { return BellTower(relay: UnavailableBellRelay(error: error)) }
  }()

  private let relay: any BellRelayOperations
  private(set) var apnsToken: Data?
  private var snapshots: [Bell.ID: CurrentValueSubject<Bell.ReceivedState?, Never>] = [:]
  private let bindingStore: BellBindingStore
  private var activationObservation: AnyCancellable?
  private var retryTask: Task<Void, Never>?
  private var retryDelay: UInt64 = 2
  private var refreshing = false
  private var refreshAgain = false

  init(relay: any BellRelayOperations = MockBellRelay(), bindingStore: BellBindingStore = BellBindingStore()) {
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
    guard let live = relay as? LiveBellRelay else { return .ignored }
    guard !refreshing else { refreshAgain = true; return .ignored }
    refreshing = true
    retryTask?.cancel(); retryTask = nil
    var failed = false
    defer {
      refreshing = false
      if refreshAgain {
        refreshAgain = false
        Task { @MainActor [weak self] in await self?.refreshState() }
      } else if failed || live.hasPendingOperations { scheduleRetry() }
      else { retryDelay = 2 }
    }
    do { try await live.synchronize(apnsToken: apnsToken) }
    catch { failed = true; Zuse.logger(.machine, "Bell").error("Relay operations remain pending: \(error.localizedDescription)") }
    do {
      let since = snapshots.mapValues { $0.value?.stateVersion ?? 0 }
      let states = try await live.fetchState(since: since)
      var result = ReceiveResult.ignored
      for (id, state) in states {
        if try applyStatus(state, for: id) == .updated { result = .updated }
      }
      return result
    } catch {
      failed = true
      Zuse.logger(.machine, "Bell").error("Relay status refresh failed: \(error.localizedDescription)")
      return .ignored
    }
  }

  // Foreground-only bounded backoff; activation/background hints remain the
  // recovery triggers when iOS suspends us. Never promise background execution.
  private func scheduleRetry() {
    guard retryTask == nil, UIApplication.shared.applicationState == .active else { return }
    let delay = retryDelay
    retryDelay = min(retryDelay * 2, 60)
    retryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
      catch { return }
      guard let self = self else { return }
      self.retryTask = nil
      guard UIApplication.shared.applicationState == .active else { return }
      await self.refreshState()
    }
  }

  func updateAPNsToken(_ token: Data) {
    guard apnsToken != token else { return }
    let changed = apnsToken != nil
    apnsToken = token
    Zuse.logger(.machine, "Bell").info(changed ? "APNs endpoint changed" : "APNs endpoint received")
    Zuse.logger(.machine, "Bell").info("CLI push: APNS_DEVICE_TOKEN='\(token.map { String(format: "%02x", $0) }.joined())'")
    Task { await refreshState() }
  }

  // MARK: Create and bind

  func createBell(name: String, ownerID: UUID? = nil) throws -> Bell {
    try relay.createBell(name: name, ownerID: ownerID)
  }

  @discardableResult
  func bind(_ bellID: Bell.ID, bellKey: String, contentSecret: String?,
            workURL: URL, level: Bell.ReceiveLevel) throws -> Bell.RelayBindingResponse {
    guard WorkURL.recognizes(workURL) else { throw BellError.invalidWorkURL }
    try attach(bellID, toWorkURL: workURL, contentSecret: contentSecret, level: level)
    do {
      let response = try relay.bind(bellID, bellKey: bellKey, apnsToken: apnsToken, level: level)
      Task { await refreshState() }
      return response
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
    Task { await refreshState() }
  }

  func retireBell(_ bellID: Bell.ID, bellKey: String) throws {
    try relay.deleteBell(bellID, bellKey: bellKey)
    let subject = snapshots.removeValue(forKey: bellID)
    subject?.send(nil)
    subject?.send(completion: .finished)
    try bindingStore.remove(bellID)

    try bindingStore.removeState(for: bellID)

    Task { await refreshState() }
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
    guard try bindingStore.binding(for: message.bellID) != nil else { return .ignored }
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
