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
import UIKit
import UserNotifications
import XCTest
@testable import Blink

// Compile the actual NSE source in this target, using the app's shared binding store and codec.
typealias BellBindingStore = Blink.BellBindingStore
typealias BellMockPush = Blink.BellMockPush

final class BellFlowTests: XCTestCase {
  private var directory: URL!
  private let endpointID = "bell-flow-device"
  private var bindingDirectory: URL { directory.appendingPathComponent("Lookup") }
  private var relayDirectory: URL { directory.appendingPathComponent("Relay") }

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  @MainActor
  func testTerminalOwnsItsBellAcrossBindingRestoreAndRetirement() throws {
    let bell: Bell
    let sessionKey: UUID
    let archive: Data
    let metaArchive: Data

    // The menu creates and stores the Bell; binding installs its local route.
    do {
      let tower = makeTower()
      let payload = MCPSessionPayload(params: MCPParams())
      let terminal = TermController(sessionPayload: payload, bellTower: tower)
      bell = try terminal.createBell(name: "Build")
      sessionKey = terminal.meta.key
      XCTAssertEqual(payload.bell, bell)
      XCTAssertEqual(try terminal.createBell(name: "Repeated menu action"), bell)
      XCTAssertEqual(try tower.workURL(for: bell.id), WorkURL.terminal(sessionKey))
      XCTAssertEqual(try terminal.bellBinding?.level, .loud)
      XCTAssertEqual(try terminal.bellBinding?.workURL, WorkURL.terminal(sessionKey))
      XCTAssertNil(payload.session, "Bell creation must not start the shell")

      let silent = try terminal.bindBell(level: .silent)
      XCTAssertEqual(try terminal.bellBinding?.level, silent.level)
      XCTAssertEqual(silent.level, .silent)
      XCTAssertEqual(silent.bellID, bell.id)
      XCTAssertEqual(silent.endpointID, endpointID)
      XCTAssertThrowsError(try tower.unbind(bell.id, bellKey: bell.token), "SEND cannot manage a binding")
      XCTAssertEqual(try terminal.bellBinding?.level, .silent)

      // Any rejected bind removes the attachment, including an update to an existing binding.
      XCTAssertThrowsError(try tower.bind(bell.id, bellKey: bell.token, contentSecret: nil,
                                         workURL: WorkURL.terminal(UUID()), level: .loud))
      XCTAssertNil(try terminal.bellBinding)
      XCTAssertNil(try tower.workURL(for: bell.id))
      let rejected = ring(bell.id, status: nil)
      XCTAssertEqual(try deliver(rejected, through: makeService()), rejected.content)

      try terminal.bindBell(level: .silent)
      XCTAssertEqual(try terminal.bellBinding?.level, .silent)
      XCTAssertEqual(try tower.workURL(for: bell.id), WorkURL.terminal(sessionKey))

      let coder = NSKeyedArchiver(requiringSecureCoding: true)
      payload.encode(with: coder)
      coder.finishEncoding()
      archive = coder.encodedData
      metaArchive = try JSONEncoder().encode(terminal.meta)
    }

    // Neither the original Terminal nor its Tower is available to the extension.
    let request = ring(bell.id, status: ["state": "ok", "progress": 100])
    let prepared = try deliver(request, through: makeService())
    XCTAssertEqual(prepared.targetContentIdentifier, WorkURL.terminal(sessionKey).absoluteString)

    let tower = makeTower()
    XCTAssertEqual(try tower.workURL(for: bell.id), WorkURL.terminal(sessionKey))
    let coder = try NSKeyedUnarchiver(forReadingFrom: archive)
    let payload = try XCTUnwrap(decodePayload(from: coder))
    coder.finishDecoding()
    let meta = try JSONDecoder().decode(SessionMeta.self, from: metaArchive)
    let terminal = TermController(sessionPayload: payload, bellTower: tower, sessionMeta: meta)
    XCTAssertEqual(terminal.meta.key, sessionKey)
    XCTAssertEqual(terminal.bell, bell)
    XCTAssertEqual(try terminal.bellBinding?.level, .silent, "Binding survives Tower replacement without rebinding")
    let receiveMenu = try XCTUnwrap(terminal.bellMenuElements().compactMap { $0 as? UIMenu }.first)
    XCTAssertEqual(receiveMenu.title, "Receive")
    let selectedLevel = receiveMenu.children.compactMap { $0 as? UIAction }.first { $0.state == .on }
    XCTAssertEqual(selectedLevel?.title, "Silent")
    XCTAssertNil(terminal.bellState, "NSE delivery does not yet persist or recover status")

    try terminal.unbindBell() // the menu's Off operation
    XCTAssertNil(try terminal.bellBinding)
    XCTAssertNil(try tower.workURL(for: bell.id))
    XCTAssertEqual(try terminal.createBell(name: "Still exists"), bell)
    XCTAssertNil(try terminal.bellBinding, "Knowing a Bell does not implicitly rebind it")
    XCTAssertNil(try makeTower().localBinding(for: bell.id), "Unbinding survives Tower replacement too")

    // An already-prepared alert opens through its own Work URL after unbinding.
    let url = try XCTUnwrap(prepared.targetContentIdentifier.flatMap(URL.init(string:)))
    let command = try XCTUnwrap(SceneCommands.from(url: url) as? OpenTerminalCommand)
    XCTAssertEqual(command.sessionKey, sessionKey)
    XCTAssertEqual(try deliver(request, through: makeService()), request.content,
                   "An in-flight alert without a lookup falls back unchanged")

    XCTAssertThrowsError(try tower.bind(bell.id, bellKey: bell.bellKey, contentSecret: nil,
                                       workURL: URL(string: "blink://unsupported")!, level: .loud))
    XCTAssertNil(try terminal.bellBinding, "No work, no binding")
    XCTAssertThrowsError(try tower.bind(bell.id, bellKey: bell.token, contentSecret: nil,
                                       workURL: WorkURL.terminal(sessionKey), level: .loud))
    XCTAssertNil(try terminal.bellBinding, "A rejected first bind removes its provisional lookup")
    XCTAssertNil(try tower.workURL(for: bell.id))

    let rebound = try terminal.bindBell(level: .loud)
    XCTAssertEqual(rebound.bellID, bell.id)
    XCTAssertEqual(rebound.endpointID, endpointID)
    XCTAssertEqual(try terminal.bellBinding?.level, .loud)

    var finished = false
    let observation = tower.observe(bell.id).sink(receiveCompletion: { _ in finished = true }, receiveValue: { _ in })
    defer { observation.cancel() }
    try terminal.retireBell()
    XCTAssertNil(payload.bell)
    XCTAssertNil(terminal.bellState)
    XCTAssertNil(try tower.localBinding(for: bell.id))
    XCTAssertNil(try tower.workURL(for: bell.id))
    XCTAssertNil(try BellBindingStore(directoryURL: bindingDirectory).binding(for: bell.id))
    XCTAssertTrue(finished, "Retiring the owner ends its state observation")

    let late = try deliver(request, through: makeService())
    XCTAssertEqual(late, request.content, "A late alert cannot target the retired Terminal")
    let message = try XCTUnwrap(Bell.Message(notificationContent: late))
    XCTAssertEqual(try tower.receiveNotificationStatus(message), .ignored)
    XCTAssertNil(tower.state(bell.id))
    XCTAssertThrowsError(try tower.bind(bell.id, bellKey: bell.bellKey, contentSecret: nil,
                                       workURL: WorkURL.terminal(sessionKey), level: .loud))
    XCTAssertNil(try tower.localBinding(for: bell.id))
  }

  @MainActor
  func testRemoteAlertsRouteAndUpdateOnlyTheirTerminal() throws {
    let tower = makeTower()
    let firstPayload = MCPSessionPayload(params: MCPParams())
    let first = TermController(sessionPayload: firstPayload, bellTower: tower)
    let second = TermController(sessionPayload: MCPSessionPayload(params: MCPParams()), bellTower: tower)
    let firstBell = try first.createBell(name: "Build")
    let secondBell = try second.createBell(name: "Deploy")
    let service = makeService()

    // Start with the second Terminal so a default-to-first routing bug is visible.
    let deploy = ring(secondBell.id, status: ["title": "Deployed", "state": "ok", "progress": 100])
    let deployed = try deliver(deploy, through: service)
    XCTAssertEqual(deployed.targetContentIdentifier, WorkURL.terminal(second.meta.key).absoluteString)
    let deployedMessage = try XCTUnwrap(Bell.Message(notificationContent: deployed))
    XCTAssertEqual(try tower.receiveNotificationStatus(deployedMessage), .updated)
    XCTAssertEqual(second.bellState?.title, "Deployed")
    XCTAssertEqual(second.bellState?.state, .ok)
    XCTAssertNil(first.bellState)

    var changes = 0
    let observation = tower.observe(firstBell.id).sink { _ in changes += 1 }
    defer { observation.cancel() }
    let build = ring(firstBell.id, status: ["title": "Building", "body": "Compiling sources", "state": "busy", "progress": 25])
    let building = try deliver(build, through: service)
    XCTAssertEqual(building.title, build.content.title)
    XCTAssertEqual(building.body, build.content.body)
    XCTAssertEqual(building.sound, build.content.sound)
    XCTAssertEqual(building.userInfo as NSDictionary, build.content.userInfo as NSDictionary)
    XCTAssertEqual(build.content.targetContentIdentifier, "mock-bell:\(firstBell.id.uuidString)")

    // Follow the same Work URL parser and scene predicate used by Blink.
    let target = try XCTUnwrap(building.targetContentIdentifier)
    let url = try XCTUnwrap(URL(string: target))
    let open = try XCTUnwrap(SceneCommands.from(url: url) as? OpenTerminalCommand)
    XCTAssertEqual(open.sessionKey, first.meta.key)
    XCTAssertTrue(WorkURL.targetPredicate(for: [WorkURL.terminal(first.meta.key)]).evaluate(with: target))
    XCTAssertFalse(WorkURL.targetPredicate(for: [WorkURL.terminal(second.meta.key)]).evaluate(with: target))

    // Use the same decoding entry as the foreground notification callback.
    let message = try XCTUnwrap(Bell.Message(notificationContent: building))
    XCTAssertTrue(message.ring)
    XCTAssertEqual(message.bellID, firstBell.id)
    XCTAssertEqual(message.title, "Build alert")
    XCTAssertEqual(message.body, "Open the Terminal for this work.")
    XCTAssertEqual(message.status?.title, "Building")
    XCTAssertEqual(message.status?.body, "Compiling sources")
    XCTAssertEqual(try tower.receiveNotificationStatus(message), .updated)
    XCTAssertEqual(first.bellState?.title, "Building")
    XCTAssertEqual(first.bellState?.body, "Compiling sources")
    XCTAssertEqual(first.bellState?.state, .busy)
    XCTAssertEqual(first.bellState?.progress, 25)
    XCTAssertEqual(second.bellState?.title, "Deployed")

    let state = first.bellState
    let changesBeforeRepeat = changes
    let repeated = try deliver(build, through: service)
    let repeatedMessage = try XCTUnwrap(Bell.Message(notificationContent: repeated))
    XCTAssertEqual(try tower.receiveNotificationStatus(repeatedMessage), .ignored)
    XCTAssertEqual(first.bellState, state)
    XCTAssertEqual(changes, changesBeforeRepeat, "Unchanged status must not trigger another UI update")

    var latest: Bell.ReceivedState?
    let lateObserver = tower.observe(firstBell.id).sink { latest = $0 }
    defer { lateObserver.cancel() }
    XCTAssertEqual(latest, state, "A listener joining after receipt immediately gets current state")

    let attentionOnly = try deliver(ring(firstBell.id, status: nil), through: service)
    XCTAssertEqual(attentionOnly.targetContentIdentifier, target)
    let attentionMessage = try XCTUnwrap(Bell.Message(notificationContent: attentionOnly))
    XCTAssertTrue(attentionMessage.ring)
    XCTAssertEqual(attentionMessage.title, "Build alert")
    XCTAssertEqual(attentionMessage.body, "Open the Terminal for this work.")
    XCTAssertNil(attentionMessage.status)
    XCTAssertEqual(try tower.receiveNotificationStatus(attentionMessage), .ignored)
    XCTAssertEqual(first.bellState, state, "An attention-only Ring must not clear prior status")

    let completed = try deliver(ring(firstBell.id, status: ["title": "Built", "state": "ok", "progress": 100]),
                                through: service)
    let completedMessage = try XCTUnwrap(Bell.Message(notificationContent: completed))
    XCTAssertEqual(try tower.receiveNotificationStatus(completedMessage), .updated)
    XCTAssertEqual(first.bellState?.progress, 100)
    XCTAssertEqual(latest, first.bellState)
    XCTAssertEqual(second.bellState?.title, "Deployed")

    // The owner can retire locally even when its Relay credential is no longer valid.
    firstPayload.bell = Bell(id: firstBell.id, name: firstBell.name, token: firstBell.token,
                            bellKey: "invalid-management-key", contentSecret: firstBell.contentSecret)
    try first.retireBell()
    XCTAssertNil(firstPayload.bell)
    XCTAssertNil(latest)
    XCTAssertNil(first.bellState)
    XCTAssertNil(try tower.localBinding(for: firstBell.id))
    XCTAssertNil(try tower.workURL(for: firstBell.id))
    let late = try deliver(build, through: service)
    XCTAssertEqual(late, build.content)
    XCTAssertEqual(try tower.receiveNotificationStatus(message), .ignored)
    XCTAssertNil(tower.state(firstBell.id))
    let relay = MockBellRelay(endpointID: endpointID, directoryURL: relayDirectory)
    XCTAssertNoThrow(try relay.bind(firstBell.id, bellKey: firstBell.bellKey, apnsToken: nil, level: .loud),
                    "The failed courtesy deletion leaves the server record for Relay cleanup")
    XCTAssertEqual(second.bellState?.title, "Deployed", "Retirement must not affect another Terminal")
    XCTAssertEqual(try tower.workURL(for: secondBell.id), WorkURL.terminal(second.meta.key))
    try second.retireBell()
  }

  @MainActor
  func testUnavailableAlertsFallBackAndDeliveryRecovers() throws {
    let tower = makeTower()
    let terminal = TermController(sessionPayload: MCPSessionPayload(params: MCPParams()), bellTower: tower)
    let bell = try terminal.createBell(name: "Build")
    let service = makeService()
    let request = ring(bell.id, status: ["state": "ok", "progress": 100])
    let target = WorkURL.terminal(terminal.meta.key).absoluteString
    XCTAssertEqual(try deliver(request, through: service).targetContentIdentifier, target)

    let unknown = ring(UUID(), status: ["state": "busy", "progress": 10])
    XCTAssertEqual(try deliver(unknown, through: service), unknown.content)
    let unknownMessage = try XCTUnwrap(Bell.Message(notificationContent: unknown.content))
    XCTAssertEqual(try tower.receiveNotificationStatus(unknownMessage), .ignored)

    let malformed = ring(bell.id, status: ["state": "ok", "progress": 101])
    XCTAssertEqual(try deliver(malformed, through: service), malformed.content)
    XCTAssertNil(Bell.Message(notificationContent: malformed.content))
    XCTAssertNil(terminal.bellState)

    // An unreadable routing record must preserve the incoming alert, not lose completion.
    let record = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: bindingDirectory,
      includingPropertiesForKeys: nil).first)
    try Data("incomplete record".utf8).write(to: record)
    XCTAssertEqual(try deliver(request, through: service), request.content)
    XCTAssertThrowsError(try terminal.bellBinding, "An unreadable lookup is not a confirmed unbound Bell")
    let receiveMenu = try XCTUnwrap(terminal.bellMenuElements().compactMap { $0 as? UIMenu }.first)
    XCTAssertEqual(receiveMenu.title, "Receive (unavailable)")

    try terminal.bindBell(level: .loud)
    XCTAssertEqual(try deliver(request, through: service).targetContentIdentifier, target,
                   "Binding replaces the damaged attachment without needing to read it")

    try terminal.unbindBell()
    XCTAssertNil(try terminal.bellBinding)
    XCTAssertNil(try tower.workURL(for: bell.id))
    let unbound = try deliver(request, through: service)
    XCTAssertEqual(unbound, request.content)
    let unboundMessage = try XCTUnwrap(Bell.Message(notificationContent: unbound))
    XCTAssertEqual(try tower.receiveNotificationStatus(unboundMessage), .ignored)
    XCTAssertNil(terminal.bellState)
    XCTAssertNil(try terminal.bellBinding, "Receipt does not bind the Bell again")

    try terminal.bindBell(level: .loud)
    let recovered = try deliver(request, through: service)
    XCTAssertEqual(recovered.targetContentIdentifier, target, "Explicit rebind restores the route")
    let message = try XCTUnwrap(Bell.Message(notificationContent: recovered))
    XCTAssertEqual(try tower.receiveNotificationStatus(message), .updated)
    XCTAssertEqual(terminal.bellState?.progress, 100)
    XCTAssertEqual(try terminal.bellBinding?.level, .loud)
    try terminal.retireBell()
  }

  @MainActor
  private func makeTower() -> BellTower {
    let relay = MockBellRelay(endpointID: endpointID, directoryURL: relayDirectory)
    let tower = BellTower(relay: relay, bindingStore: BellBindingStore(directoryURL: bindingDirectory))
    tower.updateAPNsToken(Data(repeating: 0xAB, count: 32))
    return tower
  }

  private func makeService() -> NotificationService {
    NotificationService(bindingStore: BellBindingStore(directoryURL: bindingDirectory))
  }

  private func ring(_ bellID: UUID, status: [String: Any]?) -> UNNotificationRequest {
    var envelope: [String: Any] = ["mock": true, "bell_id": bellID.uuidString, "message_id": UUID().uuidString]
    envelope["status"] = status
    let content = UNMutableNotificationContent()
    content.title = "Build alert"
    content.body = "Open the Terminal for this work."
    content.sound = .default
    let target = "mock-bell:\(bellID.uuidString)"
    content.targetContentIdentifier = target
    content.userInfo = ["bell": envelope, "aps": [
      "alert": ["title": content.title, "body": content.body],
      "mutable-content": 1, "sound": "default", "target-content-id": target
    ]]
    return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
  }

  private func deliver(_ request: UNNotificationRequest, through service: NotificationService) throws -> UNNotificationContent {
    let delivered = expectation(description: "NSE completes \(request.identifier) once")
    delivered.assertForOverFulfill = true
    var result: UNNotificationContent?
    service.didReceive(request) { content in
      result = content
      delivered.fulfill()
    }
    wait(for: [delivered], timeout: 1)
    service.serviceExtensionTimeWillExpire()
    return try XCTUnwrap(result)
  }
}
