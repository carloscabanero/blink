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

/**
 Used to save a file downloaded using SFTP
 */
class DownloadedFileBuffer: Writer {
  
  let fast: Bool
  
  var fileHandle = FileHandle()

  init(fast: Bool, localPath: String) {
    
    self.fast = fast

    let pathString = BlinkPaths.iCloudDriveDocuments()! + "/" + localPath
    let pathUrl = URL(fileURLWithPath: pathString)
    
    // Create file if it doesn't exist
    if !FileManager.default.fileExists(atPath: pathString) {
      FileManager.default.createFile(atPath: pathString, contents: nil, attributes: nil)
    } else {
      // File already exists, replace it by deleting and creating an empty one
      do {
        try FileManager.default.removeItem(atPath: pathString)
        FileManager.default.createFile(atPath: pathString, contents: nil, attributes: nil)
      } catch {
        return
      }
    }

    fileHandle = try! FileHandle(forWritingTo: pathUrl)
    fileHandle.seekToEndOfFile()
  }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    
    return Just(buf.count).map { val in
      
      if let dataToWrite = buf as AnyObject as? Data {
        
        fileHandle.write(dataToWrite)
      }

      if !self.fast {
        usleep(1000)
      }

      print("==== Wrote \(buf.count)")

      return val
    }.mapError { $0 as Error }.eraseToAnyPublisher()
  }

  func saveFile() {
    fileHandle.closeFile()
  }
}

