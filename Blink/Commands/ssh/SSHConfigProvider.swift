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
import SSH
import Combine


fileprivate let HostKeyChangedWarningMessage = """
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Host key for server changed. It is now: Public key hash %@.

An attacker might change the default server key to confuse your client into thinking the key does not exist. It is also possible that the host key has just been changed.\n
"""

fileprivate let HostKeyChangedReplaceRequestMessage = "Accepting the following prompt will replace the old fingerprint. Do you trust the host key? [Y/n]: "

fileprivate let HostKeyChangedUnknownRequestMessage = "Public key hash: %@. The server is unknown. Do you trust the host key? [Y/n]: "

fileprivate let HostKeyChangedNotFoundRequestMessage = "Public key hash: %@. The server is unknown. Do you trust the host key? [Y/n]: "
// Having access from CLI
// Having access from UI. Some parameters must already exist, others need to be tweaked.
// Pass it a host and get everything necessary to connect, but some functions still need to be setup.
class SSHClientConfigProvider {
  let device: TermDevice
  let command: SSHCommand
  
  fileprivate init(command cmd: SSHCommand, using device: TermDevice) {
    self.device = device
    self.command = cmd
  }
  
  static func config(command cmd: SSHCommand, config options: ConfigFileOptions?, using device: TermDevice) -> SSHClientConfig {
    let prov = SSHClientConfigProvider(command: cmd, using: device)
    
    let user = cmd.user ?? "carlos"
    let authMethods = prov.availableAuthMethods()
    
    // TODO Apply connection options, that is different than config.
    // The config helps in the pool, but then you can connect there in many ways.
    return SSHClientConfig(user: user,
                           proxyJump: cmd.proxyJump,
                           proxyCommand: options?.proxyCommand,
                           authMethods: authMethods,
                           loggingVerbosity: .debug,
                           verifyHostCallback: prov.cliVerifyHostCallback,
                           sshDirectory: BlinkPaths.ssh()!)
  }
}

extension SSHClientConfigProvider {
  fileprivate func availableAuthMethods() -> [AuthMethod] {
    var authMethods: [AuthMethod] = []
    
    // Explicit identity
    if let identityFile = command.identityFile {
      if let identityKey = Self.privateKey(fromIdentifier: identityFile) {
        authMethods.append(AuthPublicKey(privateKey: identityKey))
      }
    }
    
    // Host key
    if let hostKey = Self.privateKey(fromHost: command.host) {
      authMethods.append(AuthPublicKey(privateKey: hostKey))
    }
    
    // Host password
    if let password = Self.password(fromHost: command.host) {
      authMethods.append(AuthPassword(with: password))
    }
    
    // All default keys
    for defaultKey in Self.defaultKeys() {
      authMethods.append(AuthPublicKey(privateKey: defaultKey))
    }
    
    // Interactive
    authMethods.append(AuthKeyboardInteractive(requestAnswers: self.authPrompt, wrongRetriesAllowed: 3))
    
    return authMethods
  }
  
  fileprivate func authPrompt(_ prompt: Prompt) -> AnyPublisher<[String], Error> {
    var answers: [String] = []

    if prompt.userPrompts.count > 0 {
      for question in prompt.userPrompts {
        if let input = device.readline(question.prompt, secure: true) {
          answers.append(input)
        } else {
          return Fail(error: CommandError(message: "Couldn't read input"))
            .eraseToAnyPublisher()
        }
      }
    }

    return Just(answers).setFailureType(to: Error.self).eraseToAnyPublisher()
  }
  
  fileprivate static func privateKey(fromIdentifier identifier: String) -> String? {
    guard let publicKeys = (BKPubKey.all() as? [BKPubKey]) else {
      return nil
    }
    
    guard let privateKey = publicKeys.first(where: { $0.id == identifier }) else {
      return nil
    }
    
    return privateKey.privateKey
  }
  
  fileprivate static func privateKey(fromHost host: String) -> String? {

    guard let hosts = (BKHosts.all() as? [BKHosts]) else {
      return nil
    }

    guard let host = hosts.first(where: { $0.host == host }) else {
      return nil
    }

    guard let keyIdentifier = host.key, let privateKey = privateKey(fromIdentifier: keyIdentifier) else {
      return nil
    }

    return privateKey
  }
  
  fileprivate static func defaultKeys() -> [String] {
    guard let publicKeys = (BKPubKey.all() as? [BKPubKey]) else {
      return []
    }
    
    let defaultKeyNames = ["id_dsa", "id_rsa", "id_ecdsa", "id_ed25519"]
    let keys: [String] = publicKeys.compactMap { defaultKeyNames.contains($0.id) ? $0.privateKey : nil }
    
    return keys.count > 0 ? keys : []
  }
  
  fileprivate static func password(fromHost host: String) -> String? {
    guard let hosts = (BKHosts.all() as? [BKHosts]) else {
      return nil
    }
    
    guard let host = hosts.first(where: { $0.host == host }) else {
      return nil
    }
    
    return host.password
  }
}

extension SSHClientConfigProvider {
  func cliVerifyHostCallback(_ prompt: SSH.VerifyHost) -> AnyPublisher<InteractiveResponse, Error> {
    var response: SSH.InteractiveResponse = .negative

    var messageToShow: String = ""

    switch prompt {
    case .changed(serverFingerprint: let serverFingerprint):
      let headerMessage = String(format: HostKeyChangedWarningMessage, serverFingerprint)
      messageToShow = String(format: "%@\n%@", headerMessage, HostKeyChangedReplaceRequestMessage)
    case .unknown(serverFingerprint: let serverFingerprint):
      messageToShow = String(format: HostKeyChangedUnknownRequestMessage, serverFingerprint)
    case .notFound(serverFingerprint: let serverFingerprint):
      messageToShow = String(format: HostKeyChangedNotFoundRequestMessage, serverFingerprint)
    @unknown default:
      break
    }

    let readAnswer = self.device.readline(messageToShow, secure: false)

    if let answer = readAnswer?.lowercased() {
      if answer.starts(with: "y") {
        response = .affirmative
      }
    } else {
      printLn("Cannot read input.")
    }

    return Just(response).setFailureType(to: Error.self).eraseToAnyPublisher()
  }
  
  fileprivate func printLn(_ string: String) {
    let line = string.appending("\n")
    fwrite(line, line.lengthOfBytes(using: .utf8), 1, device.stream.out)
  }
}
