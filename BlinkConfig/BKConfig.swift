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

import SSHConfig


// Responsible to intermediate between the Blink Configuration formats and the
// SSHClient requirements, facilitating information between them.
// TODO This will work a lot better as a singleton.
public struct BKConfig {
  let defaultKeyNames = ["id_dsa", "id_rsa", "id_ecdsa", "id_ed25519"]

  private let _allHosts: [BKHosts]
  private let _allIdentities: [BKPubKey]
  private let bkSSHConfig: SSHConfig?

  // TODO Config files
  public init() {
    _allHosts = BKHosts.allHosts()
    _allIdentities = BKPubKey.all()
    bkSSHConfig = try? SSHConfig.parse(url: BlinkPaths.blinkGlobalSSHConfigFileURL())
  }

  private func _host(_ host: String) -> BKHosts? {
    return _allHosts.first(where: { $0.host == host })
  }

  // Return the stored configuration given the host.
  // We are assuming that configuration will be just coming from .blink/ssh_config.
  public func bkSSHHost(_ alias: String) -> BKSSHHost? {
    guard var sshConfig = try? bkSSHConfig?.resolve(alias: alias) else {
      return nil
    }

    // Add protected data (password)
    if let password = _host(alias)?.password {
      sshConfig["password"] = password
    }

    // TODO If the default information cannot be passed, we could enforce it here.
    return BKSSHHost(content: sshConfig)
  }
  
  public func bkSSHHost(_ alias: String, extending baseHost: BKSSHHost) -> BKSSHHost {
    guard let sshConfigHost = self.bkSSHHost(alias) else {
      return baseHost
    }
    
    return baseHost.merge(sshConfigHost)
  }

  public func privateKey(forIdentifier identifier: String) -> (String, String)? {
    guard
      let privateKey = _allIdentities.first(where: { $0.id == identifier })?.loadPrivateKey()
    else {
      return nil
    }
    
    return (privateKey, identifier)
  }

  public func signer(forIdentity identity: String) -> (Signer, String)? {
    guard
      let signer = _allIdentities.signerWithID(identity)
    else {
      return nil
    }
    
    return (signer, identity)
  }
  
  public func signer(forHost host: BKSSHHost) -> (Signer, String)? {
    guard
      let identity = host.identityFile
    else {
      return nil
    }
    
    return signer(forIdentity: identity)
  }

  public func defaultSigners() -> [(Signer, String)] {
    return defaultKeyNames.compactMap {
      signer(forIdentity: $0)
    }
  }
  
  public func defaultKeys() -> [(String, String)] {
    return _allIdentities
      .filter {
        defaultKeyNames.contains($0.id)
      }
      .map {
        ($0.loadPrivateKey(), $0.id)
      }
      .compactMap {
        guard
          let privateKey = $0.0
        else {
          return nil
        }
        return (privateKey, $0.1)
      }
  }

}

public struct BKSSHHost {
  private let content: [String:Any]

  public var hostName: String? { content["hostname"] as? String }
  public var identityFile: String? { content["identityfile"] as? String }
  public var password: String? { content["password"] as? String }
  public var user: String? { content["user"] as? String }
  public var port: String? { content["port"] as? String }
  public var proxyCommand: String? { content["proxycommand"] as? String }
  public var proxyJump: String? { content["proxyjump"] as? String }
  public var compression: Bool? {
    guard let compression = content["compression"] as? String else {
      return nil
    }
    return Bool(yesNoValue: compression)
  }
  public var compressionLevel: Int? {
    guard let compressionLevel = content["compressionlevel"] as? String else {
      return nil
    }
    return Int(compressionLevel)
  }
  public var connectionTimeout: Int? {
    guard let connectionTimeout = content["connectiontimeout"] as? Int else {
      return nil
    }
    return Int(connectionTimeout)
  }
  public var logLevel: SSHLogLevel? {
    guard let logLevel = content["loglevel"] as? String else {
      return nil
    }
    return SSHLogLevel(logLevel)
  }
  public var controlMaster: Bool? {
    guard let controlMaster = content["controlmaster"] as? String else {
      return nil
    }
    return Bool(yesNoValue: controlMaster)
  }

  public var forwardAgent: Bool? {
    guard let forwardAgent = content["forwardAgent"] as? String else {
      return nil
    }
    return Bool(yesNoValue: forwardAgent)
  }

  public init(content: [String: Any]) {
    self.content = content
  }

  public func merge(_ host: BKSSHHost) -> BKSSHHost {
    return BKSSHHost(content: content.merging(host.content, uniquingKeysWith: { (curr, _) in curr }))
  }

  public func sshClientConfig(authMethods: [SSH.AuthMethod]?,
                              verifyHostCallback: SSHClientConfig.RequestVerifyHostCallback? = nil,
                              agent: SSHAgent? = nil,
                              logger: SSHLogPublisher? = nil) -> SSHClientConfig {
    SSHClientConfig(
      user: user ?? "root",
      port: port,
      proxyJump: proxyJump,
      proxyCommand: proxyCommand,
      authMethods: authMethods,
      agent: agent,
      loggingVerbosity: logLevel,
      verifyHostCallback: verifyHostCallback,
      connectionTimeout: connectionTimeout,
      logger: logger,
      compression: compression,
      compressionLevel: compressionLevel
    )
  }
}

extension Bool {
  fileprivate init?(yesNoValue description: String) {
    switch description.lowercased() {
    case "yes":
      self.init(true)
    case "no":
      self.init(false)
    default:
      return nil
    }
  }
}
