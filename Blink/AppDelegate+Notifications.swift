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
  @objc(routeNotificationResponse:)
  func routeNotificationResponse(_ response: UNNotificationResponse) {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
          let delegate = response.targetScene?.delegate as? SceneDelegate else { return }
    let content = response.notification.request.content
    do {
      let workURL: URL?
      if let target = content.targetContentIdentifier, let url = URL(string: target), WorkURL.recognizes(url) {
        workURL = url
      } else if let bellID = BellWireEnvelope.bellID(content.userInfo) ?? BellMockPush.decode(content.userInfo)?.bellID {
        // Fallback notification if not processed by the NSE, try to unpack.
        workURL = try BellTower.shared.workURL(for: bellID)
      } else {
        workURL = nil
      }
      guard let url = workURL, WorkURL.recognizes(url),
            let command = SceneCommands.from(url: url) else { return }
      // [dev] REVIEW: validate cold-launch readiness and NSE scene selection on device.
      // Bell fallback resolves a URL after scene selection; it cannot retarget that scene.
      command.perform(on: delegate.spaceController)
    } catch {
      Zuse.logger(.machine, "Bell").error("Could not resolve Bell notification target")
    }
  }
}
