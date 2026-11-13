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

final class NotificationService: UNNotificationServiceExtension {
  private let bindingStore: BellBindingStore
  // Normal delivery and expiration can race (received on different threads)
  private let lock = NSLock()
  private var pending: Delivery?

  override convenience init() {
    self.init(bindingStore: BellBindingStore())
  }

  init(bindingStore: BellBindingStore) {
    self.bindingStore = bindingStore
    super.init()
  }

  override func didReceive(_ request: UNNotificationRequest,
                          withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    let delivery = Delivery(original: request.content, completion: contentHandler)
    lock.lock()
    let previous = pending
    pending = delivery
    lock.unlock()
    previous?.finishOriginal()

    do { delivery.finish(try prepareNotification(request.content)) }
    catch { delivery.finishOriginal() }
  }

  override func serviceExtensionTimeWillExpire() {
    lock.lock()
    let delivery = pending
    lock.unlock()
    delivery?.finishOriginal()
  }

  private func prepareNotification(_ original: UNNotificationContent) throws -> UNNotificationContent {
    let bellID = BellWireEnvelope.bellID(original.userInfo) ?? BellMockPush.decode(original.userInfo)?.bellID
    guard let id = bellID, let binding = try bindingStore.binding(for: id),
          let push = BellMockPush.decode(original.userInfo, contentSecret: binding.contentSecret),
          (binding.acceptsPlaintext || ((original.userInfo["bell"] as? [String: Any])?["enc"] as? Bool == true && binding.contentSecret != nil)),
          let content = original.mutableCopy() as? UNMutableNotificationContent else {
      throw PreparationError.unavailable
    }
    if !push.mock {
      if let title = push.preparedTitle { content.title = title }
      if let body = push.preparedBody { content.body = body }
    }
    if let envelope = original.userInfo["bell"] as? [String: Any], let ask = envelope["ask"] as? [String: Any] {
      guard ask["kind"] as? String == "confirm", ask["ask_id"] as? String == envelope["id"] as? String, let expires = ask["expires_at"] as? Double,
            expires > Date().timeIntervalSince1970 else { content.categoryIdentifier = ""; return content }
      content.categoryIdentifier = "BELL_CONFIRM"
    }
    content.targetContentIdentifier = binding.workURL.absoluteString
    return content
  }

  private enum PreparationError: Error { case unavailable }

  private final class Delivery {
    let original: UNNotificationContent
    private let lock = NSLock()
    private var completion: ((UNNotificationContent) -> Void)?

    init(original: UNNotificationContent,
         completion: @escaping (UNNotificationContent) -> Void) {
      self.original = original
      self.completion = completion
    }

    func finishOriginal() { finish(original) }

    func finish(_ content: UNNotificationContent) {
      lock.lock()
      let callback = completion
      completion = nil
      lock.unlock()
      callback?(content)
    }
  }
}
