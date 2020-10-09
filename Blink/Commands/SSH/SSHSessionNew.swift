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
  
  @Flag(name: .customShort("v"), help: "Only warnings")
  var verbosityLogWarning = false
  
  @Flag(name: .customLong("vv", withSingleDash: true), help: "High level protocol infomation")
  var verbosityLogProtocol = false
  
  @Flag(name: .customLong("vvv", withSingleDash: true), help: "Lower level protocol information, packet level")
  var verbosityLogPacket = false
  
  @Flag(name: .customLong("vvvv", withSingleDash: true), help: "Every function path")
  var verbosityLogFunctions = false
  
  @Option(name:  [.customLong("port"), .customShort("p")],
          default: "22",
          help: "Specifies the port to connect to on the remote host.")
  var port: String
  
  @Option(name:  [.customShort("i")],
          default: nil,
          help: "Identity file")
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
    
//    if host == nil || host.count == 0 {
//      throw  ValidationError("Missing '<host>'")
//    }
    
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
  
  override init!(device: TermDevice!, andParams params: SessionParams!) {
    
    super.init(device: device, andParams: params)
    
    self._stream = device.stream.duplicate()
    self._device = device
    self._sessionParams = params
  }
  
  func parseAuthMethods() -> AuthMethod? {
    
    /// `ssh -i <identity_file> <host>`
    /// Identity file is provided explicitly
    if let identityFile = sshCommand?.identityFile {
      
      guard let privateKey = SSHCommons.getPrivateKey(from: identityFile) else { return nil }
      
      return AuthPublicKey(privateKey: privateKey)
    }
    
    /// Getting identity file from the host
    else if sshCommand?.identityFile == nil && sshCommand?.host != nil {
      
      if let host = SSHCommons.getHosts(by: sshCommand!.host), let privateKey = SSHCommons.getPrivateKey(from: host.key) {
        return AuthPublicKey(privateKey: privateKey)
      }
    
    /// Password authentication
    } else {
      let requestAnswers: AuthKeyboardInteractive.RequestAnswersCb = { prompt in
        dump(prompt)
        
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
      
      return AuthKeyboardInteractive(requestAnswers: requestAnswers)
    }
    
    let requestAnswers: AuthKeyboardInteractive.RequestAnswersCb = { prompt in
      dump(prompt)
      
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
    
    return AuthKeyboardInteractive(requestAnswers: requestAnswers)
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
    
    if let authMethod = parseAuthMethods() {
      authMethods.append(authMethod)
    } else {
      
    }
    
    var connection: SSH.SSHClient?
    
    currentRunLoop = RunLoop.current
    
    var stream: SSH.Stream?
    var output: DispatchData?
    
    var loggingLevelToUse = SSH_LOG_NOLOG
    
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
    
    self.config = SSHClientConfig(user: sshCommand!.username, authMethods: authMethods, loggingVerbosity: loggingLevelToUse)
    
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
    
    if let cfRunLoop = self.currentRunLoop?.getCFRunLoop() {
      CFRunLoopStop(cfRunLoop)
    }
    
    self.cancellable?.cancel()
    self.libsshLoggingCancellable?.cancel()
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
