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

struct SFTPCommand: ParsableCommand {

  @Option(name:  [.customLong("port"), .customShort("P")],
          default: "22",
          help: "Specifies the port to connect to on the remote host.")
  var port: String
  
  @Option(name:  [.customShort("i")],
          default: nil,
          help: "Identity file used to authenticate")
  var identityFile: String?

  @Argument(help: "user@]host[:file ...]")
  var host: String
  
  

  @Argument(help: "Specifies local path where the destination file will be stored")
  var localPath: String

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

  var remotePath: String {
    get {
      if host.contains("@") {
        return host.components(separatedBy: "@")[1].components(separatedBy: ":")[1]
      } else {
        return host
          .components(separatedBy: ":")[1]
      }
    }
  }

  func run() throws {
    
  }

  func validate() throws {
    
  }
}


@objc class SFTPSession: Session {
  
  var cancellable: AnyCancellable?
  
  var _stream: TermStream?
  var _device: TermDevice?
  var _sessionParams: SessionParams?
  
  var startDate: Date?
  var previousIntervalDate: Date?
  
  var username: String?
  var password: String?
  var path: String?
  var host: String?
  var config: SSHClientConfig?
  var connection: SSH.SSHClient?
  
  /// Size in bytes of the latest downloaded chunk
  var latestChunkSize: Int = 0
  /// Seconds of difference between downloaded chunks
  var timeDiff: TimeInterval = 1
  
  var sftpCommand: SFTPCommand?

  var latestConsolePrintedMessage: String = ""
  
  let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()

  let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = .useAll
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter
  }()
  
  var rLoop: RunLoop?
  
  override init!(device: TermDevice!, andParams params: SessionParams!) {
    super.init(device: device, andParams: params)
    
    self._stream = device.stream.duplicate()
    self._device = device
    self._sessionParams = params
  }
  
  override func main(_ argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>!) -> Int32 {
    
    do {
      
      sftpCommand = try SFTPCommand.parse((_sessionParams as! SFTPParams).command?.components(separatedBy: " "))
      
    } catch {
      logConsole(message: error.localizedDescription)
      return -1;
    }
    
    var authMethods: [AuthMethod] = []
    
    /// Publickey authentication
    if let identityFile = sftpCommand?.identityFile {
      guard let privateKey = SSHCommons.getPrivateKey(from: identityFile) else { return -1 }
      
      authMethods.append(AuthPublicKey(privateKey: privateKey))
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
      
      authMethods.append(AuthKeyboardInteractive(requestAnswers: requestAnswers))
    }

    
    self.config = SSHClientConfig(user: sftpCommand!.username, authMethods: authMethods)

    startDownload()
    CFRunLoopRun()

    return 0;
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
  
  /// Log a message to the console
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
  
  @objc func startDownload() {
    
    guard let sftpCommand = sftpCommand else { return }
    
    var sftp: SFTPClient?
    let buffer = MemoryBuffer(fast: true, localPath: sftpCommand.localPath)
    var totalWritten = 0
    
    rLoop = RunLoop.current
    
    self.cancellable = SSHClient.dial(sftpCommand.remoteHost, with: config!)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        self.logConsole(message: "Connected to \(sftpCommand.remoteHost)", sameLine: false)
        self.connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<SFTPFile, Error> in
        sftp = client
        self.logConsole(message: "Fetching \(sftpCommand.remotePath) to \(BlinkPaths.iCloudDriveDocuments()! + "/" + sftpCommand.localPath)", sameLine: false)
        return client.open(self.sftpCommand!.remotePath)
      }.flatMap() { file -> AnyPublisher<Int, Error> in
        self.startDate = Date()
        self.previousIntervalDate = Date()
        return file.writeTo(buffer)
      }.sink(receiveCompletion: { completion in

        switch completion {
        case .finished:
          self.logConsole(message: "\nFinished download of \(sftpCommand.remotePath)", sameLine: false)
        case .failure(let error):
          self.logConsole(message: "\(error.localizedDescription)", sameLine: false)
        }

        if let cfRunLoop = self.rLoop?.getCFRunLoop() {
          CFRunLoopStop(cfRunLoop)
        }
        
      }, receiveValue: { written in

        totalWritten += written

        self.timeDiff = (Date().timeIntervalSince(self.previousIntervalDate!))
        self.latestChunkSize = written
        self.previousIntervalDate = Date()

        self.logConsole(message: "\(self.byteCountFormatter.string(fromByteCount: Int64(totalWritten)))  \(self.relativeDateFormatter.localizedString(for: self.startDate ?? Date(), relativeTo: Date()))  \(self.byteCountFormatter.string(fromByteCount: Int64(Double(self.latestChunkSize) * 1.0 / self.timeDiff)))/s", sameLine: true)
      })
  }
}



class MemoryBuffer: Writer {
  var count = 0
  let fast: Bool
  var data = DispatchData.empty

  var outputStream: OutputStream?

  var fileHandle: FileHandle?

  init(fast: Bool, localPath: String) {
    self.fast = fast

    let pathString = BlinkPaths.iCloudDriveDocuments()! + "/" + localPath //URL(fileURLWithPath: )
    let pathUrl = URL(fileURLWithPath: pathString)

    guard let outputStream = OutputStream(url: pathUrl, append: true) else {
      fatalError()
    }

    self.outputStream = outputStream

    // Create file if it doesn't exist
    if !FileManager.default.fileExists(atPath: pathString) {
      FileManager.default.createFile(atPath: pathString, contents: nil, attributes: nil)
    }

    fileHandle = try! FileHandle(forWritingTo: pathUrl)
    fileHandle!.seekToEndOfFile()
  }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {

    fileHandle?.write((buf as AnyObject as! Data))

    return Just(buf.count).map { val in
      self.count += buf.count

      if !self.fast {
        usleep(1000)
      }

      print("==== Wrote \(self.count)")

      return val
    }.mapError { $0 as Error }.eraseToAnyPublisher()
  }

  func saveFile() {
    fileHandle?.closeFile()
  }
}

