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

@objc class SFTPSession: Session {
  
  let usageFormat = """
  usage: sftp [-46aCfpqrv] [-B buffer_size] [-b batchfile] [-c cipher]
          [-D sftp_server_path] [-F ssh_config] [-i identity_file]
          [-J destination] [-l limit] [-o ssh_option] [-P port]
          [-R num_requests] [-S program] [-s subsystem | sftp_server]
          destination
  """
  
  var cancellable: AnyCancellable?
  
  var _stream: TermStream?
  var _device: TermDevice?
  var _sessionParams: SessionParams?
  
  var username: String?
  var password: String?
  var path: String?
  var host: String?
  var config: SSHClientConfig?
  var connection: SSH.SSHClient?
  
  var t: Thread?

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
  
  var doingOperation: Bool = false
  
  override init!(device: TermDevice!, andParams params: SessionParams!) {
    super.init(device: device, andParams: params)
    
    _stream = device.stream.duplicate()
    _device = device
    _sessionParams = params
  }
  
  override func main(_ argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>!) -> Int32 {
    // TODO: Process args
    // TODO: See Swift CLI apps command parsing
    username = "javierdemartin"
    password = "queiles"
    //    path = "/Users/javierdemartin/TestSftpFile.dat"
    path = "/Users/javierdemartin/xcode.xip"
    host = "192.168.86.22"
    
    self.config = SSHClientConfig(user: username!, authMethods: [AuthPassword(with: password!)])
    
    startDownload()
    
    /// TODO: See threads & RunLoops
    while (doingOperation) {
      RunLoop.current.run(mode: .default, before: Date.distantFuture)
    }

    return 0;
  }
  
  override func handleControl(_ control: String!) -> Bool {
    
    logConsole(message: "", sameLine: false)
    
    super.handleControl(control)
    
    if (control == "\u{03}") {
      doingOperation = false
      self.cancellable?.cancel()
    }
    
    return true
  }
  
  func randomString(length: Int) -> String {
    let letters = " "
    return String((0..<length).map{ _ in letters.randomElement()! })
  }
  
  var previousMessage = ""
  
  var startDate: Date?
  
  func logConsole(message: String, sameLine: Bool = true) {
    
    
    
    var messageToPrint = (message + "\r")
    
    if !sameLine {
      messageToPrint += "\n"
    }
    
    fputs((randomString(length: previousMessage.count + 2)).cString(using: .utf8), self._stream!.out)
    fputs("\r".cString(using: .utf8), self._stream!.out)
    
    
    fputs(messageToPrint.cString(using: .utf8), self._stream!.out)
    
    previousMessage = messageToPrint
    
  }
  
  @objc func startDownload() {
    
    var sftp: SFTPClient?
    let buffer = MemoryBuffer(fast: true)
    var totalWritten = 0
    
    doingOperation = true
    
    self.cancellable = SSHClient.dial(host!, with: config!)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        self.logConsole(message: "Connected to \(self.host!)", sameLine: false)
        self.connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<SFTPFile, Error> in
        sftp = client
        self.logConsole(message: "Fetching \(self.path!) to \(BlinkPaths.iCloudDriveDocuments()! + "/xcode.xip")", sameLine: false)
        return client.open(self.path!)
      }.flatMap() { file -> AnyPublisher<Int, Error> in
        self.startDate = Date()
        return file.writeTo(buffer)
      }.sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          self.logConsole(message: "Finished download of \(self.path!)", sameLine: false)
        case .failure(let error):
          // Problem here is we can have both SFTP and SSHError
          self.logConsole(message: "\(error.localizedDescription)", sameLine: false)
        }
        
        self.doingOperation = false
        
        self.logConsole(message: "Connection closed.")
        
      }, receiveValue: { written in
        self.logConsole(message: "\(self.byteCountFormatter.string(fromByteCount: Int64(totalWritten))) \t\(self.relativeDateFormatter.localizedString(for: self.startDate ?? Date(), relativeTo: Date()))")
        totalWritten += written
      })
  }
}

class MemoryBuffer: Writer {
  var count = 0
  let fast: Bool
  let queue: DispatchQueue
  var data = DispatchData.empty
  
  init(fast: Bool) {
    self.fast = fast
    self.queue = DispatchQueue(label: "test")
  }
  
  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    return Just(buf.count).map { val in
      self.count += buf.count
      
      self.data.append(buf)
      
      do {
        /// TODO: check hashes
        try (self.data as AnyObject as! Data).write(to: URL(fileURLWithPath: BlinkPaths.iCloudDriveDocuments()! + "/xcode.xip"))
      } catch {
        print(error.localizedDescription)
      }
      
      
      if !self.fast {
        usleep(1000)
      }
      print("==== Wrote \(self.count)")
      
      print("Done")
      return val
    }.mapError { $0 as Error }.eraseToAnyPublisher()
  }
}
