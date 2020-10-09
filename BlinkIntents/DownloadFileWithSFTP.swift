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
import Intents
import SSH
import Combine

class DownloadFileWithSFTP: NSObject, DownloadFileWithSFTPIntentHandling {
  
  var cancellable: AnyCancellable?
  
  var config: SSHClientConfig?
  var connection: SSH.SSHClient?
  
  var rLoop: RunLoop?
  
  func handle(intent: DownloadFileWithSFTPIntent, completion: @escaping (DownloadFileWithSFTPIntentResponse) -> Void) {
    
    let passwordAuth = AuthPassword(with: intent.password!)
    
    let config = SSHClientConfig(user: intent.username!, authMethods: [passwordAuth])
    
    var sftp: SFTPClient?
    let buffer = DownloadedFileBuffer(fast: true, localPath: intent.localPath!)
    
    let pathString = BlinkPaths.iCloudDriveDocuments()! + "/" + intent.localPath! //URL(fileURLWithPath: )filePath
    let pathUrl = URL(fileURLWithPath: pathString)
    
    /// Modify the URL to return a x-callback-url accesible to open the downloaded file in the Files.app
    var pathUrlComponents = URLComponents(url: pathUrl, resolvingAgainstBaseURL: false)
    pathUrlComponents?.scheme = "shareddocuments"
    
    var response: DownloadFileWithSFTPIntentResponse = DownloadFileWithSFTPIntentResponse.success(downloadedPath: pathUrlComponents!.url!.absoluteString)
        
    rLoop = RunLoop.current
    
    self.cancellable = SSHClient.dial(intent.host!, with: config)
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        self.connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<SFTPFile, Error> in
        sftp = client
        return client.open(intent.remotePath!)
      }.flatMap() { file -> AnyPublisher<Int, Error> in
        
        return file.writeTo(buffer)
      }.sink(receiveCompletion: { completionn in
        
        buffer.saveFile()
        
        switch completionn {
        case .finished:
          response = DownloadFileWithSFTPIntentResponse.success(downloadedPath: pathUrlComponents!.url!.absoluteString)
        case .failure(let error):
          response = DownloadFileWithSFTPIntentResponse.failure(downloadErrorReason: error.localizedDescription)
        }
        
        
        if let cfRunLoop = self.rLoop?.getCFRunLoop() {
          CFRunLoopStop(cfRunLoop)
        }
        
        completion(response)
        
      }, receiveValue: { _ in })
    
    CFRunLoopRun()
    
  }
}
