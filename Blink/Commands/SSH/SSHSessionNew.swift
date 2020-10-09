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
  
  @Option(name:  [.customLong("port"), .customShort("P")],
          default: "22",
          help: "Specifies the port to connect to on the remote host.")
  var port: String
  
  @Option(name:  [.customShort("v")],
          help: "Verbose mode. Causes ssh to print debugging messages about its progress. This is helpful in debugging connection, authentication, and configuration problems. Multiple -v options increase the verbosity. The maximum is 3.")
  var verboseLevelMinimum: String?
  
  @Option(name:  [.customLong("vv")],
          help: "Verbose mode. Causes ssh to print debugging messages about its progress. This is helpful in debugging connection, authentication, and configuration problems. Multiple -v options increase the verbosity. The maximum is 3.")
  var verboseLevelMedium: String?
  
  @Option(name:  [.customLong("vvv")],
          help: "Verbose mode. Causes ssh to print debugging messages about its progress. This is helpful in debugging connection, authentication, and configuration problems. Multiple -v options increase the verbosity. The maximum is 3.")
  var verboseLevelMaximum: String?
  
  @Option(name:  [.customShort("i")],
          default: nil,
          help: "Selects a file from which the identity (private key) for RSA or DSA authentication is read. The default is ~/.ssh/identity for protocol version 1, and ~/.ssh/id_rsa and ~/.ssh/id_dsa for protocol version 2. Identity files may also be specified on a per-host basis in the configuration file. It is possible to have multiple -i options (and multiple identities specified in configuration files).")
  var identityFile: String?
  
  @Argument(help: "user@]host[:file ...]")
  var host: String
  
  static let configuration = CommandConfiguration(abstract: """
  usage: sftp [-46aCfpqrv] [-B buffer_size] [-b batchfile] [-c cipher]
          [-D sftp_server_path] [-F ssh_config] [-i identity_file]
          [-J destination] [-l limit] [-o ssh_option] [-P port]
          [-R num_requests] [-S program] [-s subsystem | sftp_server]
          destination
  """)
  
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
    
    if host == nil || host.count == 0 {
      throw  ValidationError("Missing '<host>'")
    }
    
  }
}

struct BKCommandError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    public var localizedDescription: String {
        return message
    }
}

@objc class SSHSessionNew: Session {
  
  var cancellable: AnyCancellable?
  var _stream: TermStream?
  var _device: TermDevice?
  var _sessionParams: SessionParams?
  
  var rLoop: RunLoop?
  
  var config: SSHClientConfig?
  var connection: SSH.SSHClient?
  
  var sshCommand: SSHCommand?
  
  var latestConsolePrintedMessage: String = ""
  
  var authMethods: [AuthMethod] = []
  
  override init!(device: TermDevice!, andParams params: SessionParams!) {
    
    super.init(device: device, andParams: params)
    
    self._stream = device.stream.duplicate()
    self._device = device
    self._sessionParams = params
  }
  
  func parseAuthMethods() -> AuthMethod? {
    
    /// Publickey authentication
    if let identityFile = sshCommand?.identityFile {
      
      guard let privateKey = SSHCommons.getPrivateKey(from: identityFile) else { return nil }
      
      return AuthPublicKey(privateKey: privateKey)
    }
    /// Password authentication
    else {
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
  }
  
  override func main(_ argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>!) -> Int32 {
    
    do {
      
      _stream.out
      
      sshCommand = try SSHCommand.parse((_sessionParams as! SFTPParams).command?.components(separatedBy: " "))
      
    } catch {
      logConsole(message: (error as NSError).description)
      
      return -1
    }
    
    if let authMethod = parseAuthMethods() {
      authMethods.append(authMethod)
    } else {
      
    }
    
    var connection: SSH.SSHClient?
    
    rLoop = RunLoop.current
    
    self.config = SSHClientConfig(user: sshCommand!.username, authMethods: authMethods)

    cancellable = SSHClient.dial(sshCommand!.remoteHost, with: config!)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          self.logConsole(message: error.localizedDescription)
          if let cfRunLoop = self.rLoop?.getCFRunLoop() {
            CFRunLoopStop(cfRunLoop)
          }
        }
      }, receiveValue: { conn in
        connection = conn
      })

    
    CFRunLoopRun()
    
    return 0
  }
  
  override func handleControl(_ control: String!) -> Bool {
    
    super.handleControl(control)
    
    logConsole(message: "\n", sameLine: false)
    
    // Handle Ctrl-C key press
    if (control == "\u{03}") {
      self.cancellable?.cancel()
      cancellable = nil
      _stream?.close()
      
      /// Cancel the RunLoop of the executed command
      if let cfRunLoop = rLoop?.getCFRunLoop() {
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
