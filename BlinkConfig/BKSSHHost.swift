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


public struct BKSSHHost {
  private let content: [String:Any]

  public var hostName: String?
  public var identityFile: [String]?
  public var password: String?
  public var user: String?
  public var port: String?
  public var proxyCommand: String?
  public var proxyJump: String?
  public var compression: Bool?
  public var compressionLevel: Int?
  public var connectionTimeout: Int?
  public var logLevel: SSHLogLevel?
  public var controlMaster: ControlMasterOption?
  public var forwardAgent: Bool?
  public var sendEnv: [String]?
  // TODO SendEnv, Tunnels, etc...
  
  struct ValidationError: Error {
    let message: String
    public var description: String { message }
  }
  
  public init(content: [String: Any]) throws {
    self.content = content
    
    // TODO May get rid of the for loop
    // TODO Maybe the castValue functions could be part of the library?
    for (key, value) in content {
      do {
        switch key.lowercased() {
        case "hostname":            self.hostName           = try Self.castValue(value)
        case "identityfile":        self.identityFile       = try Self.castValue(value)
        case "password":            self.password           = try Self.castValue(value)
        case "user":                self.user               = try Self.castValue(value)
        case "port":                self.port               = try Self.castValue(value)
        case "proxycommand":        self.proxyCommand       = try Self.castValue(value)
        case "proxyjump":           self.proxyJump          = try Self.castValue(value)
        case "compression":         self.compression        = try Self.castValue(value)
        case "compressionlevel":    self.compressionLevel   = try Self.castValue(value)
        case "connectiontimeout":   self.connectionTimeout  = try Self.castValue(value)
        case "loglevel":            self.logLevel           = try Self.castValue(value)
        case "controlmaster":       self.controlMaster      = try Self.castValue(value)
        case "forwardagent":        self.forwardAgent       = try Self.castValue(value)
        case "sendenv":             self.sendEnv            = try Self.castValue(value)
        default:
          // Skip unknown
          break
        }
      } catch let error as ValidationError {
        throw ValidationError(message: "\(key) \(value) - \(error.message)")
      }
    }
    
  }

  // TODO Refactor into separate functions.
  static private func castValue<T>(_ value: Any) throws -> T {
    switch T.self {
    case is String?.Type:
      guard let value = value as? T else {
        throw ValidationError(message: "Type requires String")
      }
      return value
    case is Bool?.Type:
      guard let str = value as? String,
            let value = Bool(yesNoValue: str) as? T else {
        throw ValidationError(message: "Type requires yes/no")
      }
      return value
    case is Int?.Type:
      guard let str = value as? String,
            let value = Int(str) as? T else {
        throw ValidationError(message: "Type requires number")
      }
      return value
    case is SSHLogLevel?.Type:
      guard let str = value as? String,
            let value = SSHLogLevel(str) as? T else {
        throw ValidationError(message: "Type requires log level: QUIET, etc")
      }
      return value
    case is [String]?.Type:
      guard let value = value as? T else {
        // Try separating a single string
        guard let value = value as? String else {
          throw ValidationError(message: "Type requires list of strings")
        }
        return value.split(separator: " ").map { String($0) } as! T
      }
      return value
    case is ControlMasterOption?.Type:
      guard let str = value as? String,
            let value = ControlMasterOption(rawValue: str) as? T else {
        throw ValidationError(message: "Wrong option")
      }
      return value
    default:
      throw ValidationError(message: "Unknown type")
    }
  }
  
  public func merge(_ host: BKSSHHost) throws -> BKSSHHost {
    // TODO In the standard, some properties are additive, like sendenv, identities and tunnels.
    return try BKSSHHost(content: content.merging(host.content, uniquingKeysWith: { (curr, _) in curr }))
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

public enum ControlMasterOption: String {
  case auto     = "auto"
  case ask      = "ask"
  case autoask  = "autoask"
  case yes      = "yes"
  case no       = "no"
}
