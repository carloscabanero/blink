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

@MainActor
extension AppDelegate {
  @objc(startBellTower)
  func startBellTower() {
    BellTower.shared.start()
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
