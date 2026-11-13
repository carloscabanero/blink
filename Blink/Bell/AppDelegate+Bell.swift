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

import UIKit
import UserNotifications
import StoreKit

// App composition root: the transport knows neither product IDs nor build settings.
@MainActor struct BellAppPurchaseProof: BellPurchaseProofProvider {
  func enrollmentProof() async throws -> String {
    #if DEBUG
    if let token = ProcessInfo.processInfo.environment["BELL_PAID_TOKEN"], !token.isEmpty { return token }
    #endif
    let products: Set<String> = [ProductBlinkPlusID, ProductBlinkShellPlusID,
                                 ProductBlinkBuildBasicID, ProductBlinkPlusBuildBasicID]
    if #available(iOS 15.0, *) {
      for await entitlement in StoreKit.Transaction.currentEntitlements {
        if case .verified(let transaction) = entitlement, products.contains(transaction.productID),
           transaction.revocationDate == nil, transaction.expirationDate.map({ $0 > Date() }) ?? true {
          return entitlement.jwsRepresentation
        }
      }
    }
    throw LiveBellRelay.Failure.missingEnrollment
  }
}

@MainActor enum BellAppSetup {
  static func makeTower() -> BellTower {
    let info = Bundle.main.infoDictionary ?? [:]
    func setting(_ key: String, fallback: String) -> String {
      guard let value = info[key] as? String, !value.isEmpty, !value.contains("$(") else { return fallback }
      return value
    }
    guard setting("BELL_RELAY_ENABLED", fallback: "YES") != "NO" else {
      return BellTower(relay: UnavailableBellRelay(error: BellSetupError.disabled))
    }
    #if DEBUG
    let defaultEnvironment = "sandbox"
    // Diagnostic launch overrides remain available for Carlos's development Relay.
    let address = UserDefaults.standard.string(forKey: "BellRelayURL") ?? setting("BELL_RELAY_URL", fallback: "https://bell.blink.sh")
    let environment = UserDefaults.standard.string(forKey: "BellAPNsEnvironment") ?? setting("BELL_APNS_ENVIRONMENT", fallback: defaultEnvironment)
    #else
    let address = setting("BELL_RELAY_URL", fallback: "https://bell.blink.sh")
    let environment = setting("BELL_APNS_ENVIRONMENT", fallback: "production")
    #endif
    guard let url = URL(string: address), let topic = Bundle.main.bundleIdentifier else {
      return BellTower(relay: UnavailableBellRelay(error: LiveBellRelay.Failure.configuration))
    }
    let configuration = LiveBellRelay.Configuration(baseURL: url, topic: topic, environment: environment)
    guard configuration.isValid else { return BellTower(relay: UnavailableBellRelay(error: LiveBellRelay.Failure.configuration)) }
    do { return BellTower(relay: try LiveBellRelay(configuration: configuration, proofProvider: BellAppPurchaseProof())) }
    catch { return BellTower(relay: UnavailableBellRelay(error: error)) }
  }
}

enum BellSetupError: LocalizedError {
  case disabled
  var errorDescription: String? { "Bell Relay is disabled in this build." }
}

@MainActor
extension AppDelegate {
  @objc(startBellTower)
  func startBellTower() {
    let actions = [UNNotificationAction(identifier: "BELL_APPROVE", title: "Approve", options: [.authenticationRequired]),
                   UNNotificationAction(identifier: "BELL_DENY", title: "Deny", options: [.authenticationRequired])]
    let category = UNNotificationCategory(identifier: "BELL_CONFIRM", actions: actions, intentIdentifiers: [])
    UNUserNotificationCenter.current().getNotificationCategories { existing in
      var categories = existing.filter { $0.identifier != "BELL_CONFIRM" }; categories.insert(category)
      UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
    BellTower.shared = BellAppSetup.makeTower()
    BellTower.shared.start()
  }

  @objc(handleBellAction:completionHandler:)
  func handleBellAction(_ response: UNNotificationResponse, completionHandler: @escaping () -> Void) -> Bool {
    guard ["BELL_APPROVE", "BELL_DENY"].contains(response.actionIdentifier) else { return false }
    let info = response.notification.request.content.userInfo
    guard let bellID = BellWireEnvelope.bellID(info), let envelope = info["bell"] as? [String: Any],
          let ask = envelope["ask"] as? [String: Any], let askID = ask["ask_id"] as? String, askID == envelope["id"] as? String,
          envelope["enc"] as? Bool == true,
          let binding = try? BellBindingStore().binding(for: bellID),
          BellMockPush.decode(info, contentSecret: binding.contentSecret) != nil else { completionHandler(); return true }
    Task { @MainActor in
      await BellTower.shared.answerAsk(bellID: bellID, askID: askID, verdict: response.actionIdentifier == "BELL_APPROVE" ? "approve" : "deny")
      completionHandler()
    }
    return true
  }

  // MARK: APNs registration

  @objc(updateBellAPNsToken:)
  func updateBellAPNsToken(_ token: Data) {
    BellTower.shared.updateAPNsToken(token)
  }

  // MARK: Receipt

  @objc(handleBellBackgroundNotification:completionHandler:)
  func handleBellBackgroundNotification(_ userInfo: [AnyHashable: Any],
                                        completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
    guard userInfo["bell"] != nil else { return false }
    guard let aps = userInfo["aps"] as? [String: Any],
          aps["content-available"] as? Int == 1,
          aps["alert"] == nil, aps["sound"] == nil, aps["badge"] == nil else {
      completionHandler(.noData)
      return true
    }
    guard let bellID = BellWireEnvelope.bellID(userInfo) ?? BellMockPush.decode(userInfo)?.bellID else {
      completionHandler(.failed)
      return true
    }
    Task { @MainActor in
      switch await BellTower.shared.refreshState(for: bellID) {
      case .ignored: completionHandler(.noData)
      case .updated: completionHandler(.newData)
      }
    }
    return true
  }

  // Foreground presentation
  // Apply optional Bell status through Tower, then request system presentation.
  @objc(presentBellNotification:)
  func presentBellNotification(_ notification: UNNotification) -> UNNotificationPresentationOptions {
    // Missing or unchanged status must not suppress presentation.
    processBellNotificationStatus(notification)
    return [.sound, .list, .banner, .badge]
  }

  private func processBellNotificationStatus(_ notification: UNNotification) {
    guard notification.request.trigger is UNPushNotificationTrigger,
          let id = BellWireEnvelope.bellID(notification.request.content.userInfo) ?? BellMockPush.decode(notification.request.content.userInfo)?.bellID,
          let binding = try? BellTower.shared.localBinding(for: id),
          binding.acceptsPlaintext || (notification.request.content.userInfo["bell"] as? [String: Any])?["enc"] as? Bool == true,
          let message = Bell.Message(notificationContent: notification.request.content, contentSecret: binding.contentSecret) else { return }
    do {
      try BellTower.shared.receiveNotificationStatus(message)
    } catch {
      Zuse.logger(.machine, "Bell").error("Could not apply Bell notification status")
    }
  }
}
