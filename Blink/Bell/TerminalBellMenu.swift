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

extension TermController {
  // Rebuilt by BlinkMenu's uncached provider; reads the persisted local binding.
  @objc func bellMenuElements() -> [UIMenuElement] {
    guard bell != nil else {
      return [UIAction(title: "Create Bell", image: UIImage(systemName: "bell.badge")) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          do {
            // Required inputs stay explicit, including the name.
            let name = self.title.flatMap { $0.isEmpty ? nil : $0 } ?? self.meta.key.uuidString
            let bell = try self.createBell(name: name)
            let granted = try await BellTower.shared.requestNotificationPermission()
            self.showBellToken(bell.token, alertsAvailable: granted)
          } catch { self.showBellError(error) }
        }
      }]
    }

    let binding: Bell.LocalBinding?
    let bindingReadable: Bool
    do {
      binding = try bellBinding
      bindingReadable = true
    } catch {
      binding = nil
      bindingReadable = false
      Zuse.logger(.machine, "Bell").error("Could not read Bell binding: \(error.localizedDescription)")
    }
    let copy = UIAction(title: "Copy Token", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
      guard let token = self?.bell?.token else { return }
      UIPasteboard.general.string = token
    }
    let levels: [(String, Bell.ReceiveLevel?)] = [("Off", nil), ("Silent", .silent), ("Loud", .loud)]
    let receiveTitle = !bindingReadable ? "Receive (unavailable)" : binding == nil ? "Receive (unbound)" : "Receive"
    let receive = UIMenu(title: receiveTitle, options: .singleSelection,
                        children: levels.map { title, level in
      let selected = bindingReadable && (binding == nil ? level == nil : binding?.level != nil && binding?.level == level)
      return UIAction(title: title, state: selected ? .on : .off) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          do {
            if let level = level { try self.bindBell(level: level) }
            else { try self.unbindBell() }
            if level == .loud {
              let granted = try await BellTower.shared.requestNotificationPermission()
              if !granted {
                self.showBellAlert(title: "Bell Alerts Unavailable",
                                   message: "Enable notifications for Blink in Settings. Bell state will still update.")
              }
            }
          } catch { self.showBellError(error) }
        }
      }
    })

    var elements: [UIMenuElement] = [copy, receive]
    if let state = bellState {
      let summary = [state.title, state.state?.rawValue, state.progress.map { "\($0)%" }]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
      elements.append(UIAction(title: summary.isEmpty ? "State received" : summary,
                               attributes: .disabled) { _ in })
    }
    return elements
  }

  private func showBellToken(_ token: String, alertsAvailable: Bool) {
    let permission = alertsAvailable ? "" : "\n\nAlerts are disabled. Enable notifications for Blink in Settings."
    let alert = UIAlertController(title: "Bell Token",
      message: "This prototype token is for testing in Blink.\n\n\(token)\(permission)", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in UIPasteboard.general.string = token })
    alert.addAction(UIAlertAction(title: "Done", style: .cancel))
    guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
    present(alert, animated: true)
  }

  private func showBellError(_ error: Error) {
    showBellAlert(title: "Bell", message: error.localizedDescription)
  }

  private func showBellAlert(title: String, message: String) {
    guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
