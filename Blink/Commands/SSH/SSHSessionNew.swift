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
import Combine
import SSH
import ArgumentParser

struct SSHCommand: ParsableCommand {
  
  static var configuration = CommandConfiguration(
          // Optional abstracts and discussions are used for help output.
          abstract: "A LibSSH SSH client (remote login program)",
      discussion: """
    ssh (SSH client) is a program for logging into a remote machine and for executing commands on a remote machine. It is intended to replace rlogin and rsh, and provide secure encrypted communications between two untrusted hosts over an insecure network. X11 connections and arbitrary TCP ports can also be forwarded over the secure channel.

    ssh connects and logs into the specified hostname (with optional user name). The user must prove his/her identity to the remote machine using one of several methods depending on the protocol version used (see below).
    """,

          // Commands can define a version for automatic '--version' support.
          version: "1.0.0")
  
  @Flag(name: .customShort("v"), help: "First level of logging: Only warnings")
  var verbosityLogWarning = false
  
  @Flag(name: .customLong("vv", withSingleDash: true), help: "Second level of logging: High level protocol infomation")
  var verbosityLogProtocol = false
  
  @Flag(name: .customLong("vvv", withSingleDash: true), help: "Third level of logging: Lower level protocol information, packet level")
  var verbosityLogPacket = false
  
  @Flag(name: .customLong("vvvv", withSingleDash: true), help: "Maximum level of logging: Every function path")
  var verbosityLogFunctions = false
  
  @Option(name:  [.customLong("port"), .customShort("p")],
          default: "22",
          help: "Specifies the port to connect to on the remote host.")
  var port: String
  
  @Option(name:  [.customShort("i")],
          default: nil,
          help: """
  Selects a file from which the identity (private key) for public key authentication is read. The default is ~/.ssh/id_dsa, ~/.ssh/id_ecdsa, ~/.ssh/id_ed25519 and ~/.ssh/id_rsa.  Identity files may also be specified on a per-host basis in the configuration pane in the Settings of Blink.
  """)
  var identityFile: String?
  
  @Argument(help: "user@host")
  var host: String
  
  var username: String {
    get {
      
      if host.contains("@") {
        return host.components(separatedBy: "@")[0]
      } else {
        guard let hostName = SSHCommons.getHosts(by: host.components(separatedBy: ":")[0]) else {
          return ""
        }
        
        return hostName.user!
      }
    }
  }
  
  var remoteHost: String {
    get {
      
      if host.contains("@") {
        return host.components(separatedBy: "@")[1].components(separatedBy: ":")[0]
      } else {
        guard let hostName = SSHCommons.getHosts(by: host.components(separatedBy: ":")[0]) else {
          return ""
        }
        
        return hostName.hostName!
      }
    }
  }
  
  func run() throws {
    
  }
  
  func validate() throws {

    
  }
}

@objc class SSHSessionNew: Session {
  
  var cancellable: AnyCancellable?
  var _stream: TermStream?
  var _device: TermDevice?
  var _sessionParams: SessionParams?
  
  var currentRunLoop: RunLoop?
  
  var config: SSHClientConfig?
  var connection: SSH.SSHClient?
  
  var sshCommand: SSHCommand?
  
  /**
   On commands printed on the same line
   */
  var latestConsolePrintedMessage: String = ""
  
  var libsshLoggingCancellable: AnyCancellable?
  
  var authMethods: [AuthMethod] = []
  
  var loggingLevelToUse = SSH_LOG_NOLOG
  
  override init!(device: TermDevice!, andParams params: SessionParams!) {
    
    super.init(device: device, andParams: params)
    
    self._stream = device.stream.duplicate()
    self._device = device
    self._sessionParams = params
  }
  
  func getAuthMethodsFromExplicitParameter(sshCommand: SSHCommand) -> [AuthMethod] {
    
    var authMethods: [AuthMethod] = []
    
    /// Get the specified identity file by the user
    if let identityFile = sshCommand.identityFile {
      if let privateKey = SSHCommons.getPrivateKey(from: identityFile) {
        authMethods.append(AuthPublicKey(privateKey: privateKey))
      } else {
        /// Log and warn the user that the requested file is not accessible
        logConsole(message: "Warning: Identity file \"\(identityFile)\" not accessible: No such file or directory.")
      }
    }
    
    return authMethods
  }
  
  /**
   
   */
  func getAuthMethodsFromStoredHost(forHost named: String) -> [AuthMethod] {
    /**
     1. Get the private key for the host
     2. Get password stored in host (if any)
     3. AuthNone
     */
    
    var authMethods: [AuthMethod] = []
    
    if let privateKeyForHost = SSHCommons.getPrivateKey(from: named) {
      authMethods.append(AuthPublicKey(privateKey: privateKeyForHost))
    }
    
    if let passwordForHost = SSHCommons.getPassword(from: named) {
      authMethods.append(AuthPassword(with: passwordForHost))
    }
    
    return authMethods
  }
  
  func getAuthMethodsManuallyNoStoredHost() -> [AuthMethod] {
    
    var authMethods: [AuthMethod] = []
    
    /// Get all private keys and append them
    for key in SSHCommons.getAllPrivateKeys() {
      authMethods.append(AuthPublicKey(privateKey: key.privateKey))
    }
    
    /// Add an Interactive method
    let requestAnswers: AuthKeyboardInteractive.RequestAnswersCb = { prompt in

      var answers: [String] = []

      if prompt.userPrompts.count > 0 {
        for question in prompt.userPrompts {
          if let input = self._device?.readline(question.prompt, secure: true) {
            answers.append(input)
          }
        }

      } else {
        answers = []
      }

      return Just(answers).setFailureType(to: Error.self).eraseToAnyPublisher()
    }

    authMethods.append(AuthKeyboardInteractive(requestAnswers: requestAnswers))
    
    /// Append a none auth method just in case
    authMethods.append(AuthNone())
    
    return authMethods
  }
  
  override func main(_ argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>!) -> Int32 {
  
    do {
      sshCommand = try SSHCommand.parse((_sessionParams as! SFTPParams).command?.components(separatedBy: " "))
    } catch {
      // Show the user any possible command validation or missing parameters
      let message = SSHCommand.message(for: error)
      logConsole(message: message)
      
      return -1
    }
    
    if let sshCommand = sshCommand {
      authMethods.append(contentsOf: getAuthMethodsFromExplicitParameter(sshCommand: sshCommand))
    }
    
    if let host = sshCommand?.host {
      authMethods.append(contentsOf: getAuthMethodsFromStoredHost(forHost: host))
    }

    authMethods.append(contentsOf: getAuthMethodsManuallyNoStoredHost())
    
    // TODO: Add manual parameters like -i
    
    var connection: SSH.SSHClient?
    
    currentRunLoop = RunLoop.current
    
    var stream: SSH.Stream?
    var output: DispatchData?
    
    if let sshCommand = sshCommand {
      if sshCommand.verbosityLogFunctions {
        loggingLevelToUse = SSH_LOG_FUNCTIONS
      } else if sshCommand.verbosityLogPacket {
        loggingLevelToUse = SSH_LOG_PROTOCOL
      } else if sshCommand.verbosityLogProtocol {
        loggingLevelToUse = SSH_LOG_PROTOCOL
      } else if sshCommand.verbosityLogWarning {
        loggingLevelToUse = SSH_LOG_WARNING
      }
    }

    /// Asks the user for confirmation whenever the private key changes
    let requestAnswers: SSHClientConfig.RequestVerifyHostCallback = { (prompt) in

      var answers: String = ""
        
        for p in prompt.userPrompts {
          print(p.prompt)
          
          if p.echo {
            if let input = self._device?.readline(p.prompt, secure: false) {
              answers.append(input)
            }
            
          } else {
            self.logConsole(message: p.prompt)
          }
        }
      
        return Just(answers).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    
    self.config = SSHClientConfig(user: sshCommand!.username, authMethods: authMethods, loggingVerbosity: loggingLevelToUse, verifyHostCallback: requestAnswers, sshDirectory: BlinkPaths.ssh()!)
    
    let bkOutputStream = BKOutputStream(stream: _stream!.out)
    
    self.libsshLoggingCancellable = SSHClient.sshLoggingPublisher.sink(receiveCompletion: { comp in
      switch comp {
      case .finished:
        break
      }
    }, receiveValue: {msg in
      self.logConsole(message: msg)
    })
    
    cancellable = SSHClient.dial(sshCommand!.remoteHost, with: config!)
      .flatMap() { conn -> AnyPublisher<SSH.Stream, Error> in
          connection = conn
          return conn.requestInteractiveShell()
      }.sink(receiveCompletion: { comp in
        switch comp {
        
        case .finished:
          break
        case .failure(let error as SSHError):
          self.logConsole(message: error.description)
          self.kill()
          
        case .failure(let genericError):
          self.logConsole(message: genericError.localizedDescription)
          self.kill()
        }
      }, receiveValue: { pty in
        stream = pty
        stream?.connect(stdout: bkOutputStream)
      })
    
    CFRunLoopRun()
        
    return 0
  }
  
  override func kill() {
    super.kill()
    
    self.cancellable?.cancel()
    self.libsshLoggingCancellable?.cancel()

    _stream?.close()
    
    /// Cancel the RunLoop of the executed command
    if let cfRunLoop = currentRunLoop?.getCFRunLoop() {
      CFRunLoopStop(cfRunLoop)
    }
  }
  
  override func handleControl(_ control: String!) -> Bool {
    
    super.handleControl(control)
    
    logConsole(message: "\n", sameLine: false)
    
    // Handle Ctrl-<C> key press
    if (control == "\u{03}") {
      self.cancellable?.cancel()
      cancellable = nil
      _stream?.close()
      
      /// Cancel the RunLoop of the executed command
      if let cfRunLoop = currentRunLoop?.getCFRunLoop() {
        CFRunLoopStop(cfRunLoop)
      } else {
        return false
      }
    }
    
    return true
  }
  
  func logConsole(message: String, sameLine: Bool = false) {
    
    guard let outputStream = self._stream?.out else {
      return
    }
    
    var messageToPrint = (message + "\r")
    
    if !sameLine {
      messageToPrint += "\n"
    } else if sameLine {
      fputs((latestConsolePrintedMessage + "\r").cString(using: .utf8), outputStream)
      // Print "fake" spaces to delete previous output
      fputs((String(repeating: " ", count: latestConsolePrintedMessage.count + 2) + "\r").cString(using: .utf8), outputStream)
    }
    
    fputs(messageToPrint.cString(using: .utf8), outputStream)
    latestConsolePrintedMessage = messageToPrint
  }
}
