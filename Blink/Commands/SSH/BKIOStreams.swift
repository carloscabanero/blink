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


import Dispatch
import Foundation
import Combine
import SSH

public enum BKStreamError: Error {
  case read
  case write
  public var description: String {
    switch self {
    case .read:
      return "Read Error"
    case .write:
      return "Write Error"
    }
  }
}

class BKOutputStream: Writer {
  
  let stream: DispatchIO
  let queue: DispatchQueue
  //var stream: UnsafeMutablePointer<FILE>?
  
  init(stream: Int32) {
    self.queue = DispatchQueue(label: "file-\(stream)")
    self.stream = DispatchIO(type: .stream, fileDescriptor: stream, queue: self.queue, cleanupHandler: { _ in
      
    })
    self.stream.setLimit(lowWater: 0)
  }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    let pub = PassthroughSubject<Int, Error>()

    return pub.handleEvents(receiveRequest: { _ in
      self.stream.write(offset: 0, data: buf, queue: self.queue) { (done, bytes, error) in
        if error == POSIXErrorCode.ECANCELED.rawValue {
          return
        }

        if error != 0 {
          pub.send(completion: .failure(BKStreamError.write))
          return
        }
        
        if done {
          pub.send(length)
          pub.send(completion: .finished)
        }
      }
    }).eraseToAnyPublisher()
  }
}

class BKInputStream {
  let stream: DispatchIO
  let queue: DispatchQueue
  
  init(stream: Int32) {
    self.queue = DispatchQueue(label: "file-\(stream)")
    self.stream = DispatchIO(type: .stream, fileDescriptor: stream, queue: self.queue, cleanupHandler: { err in
      if err != 0 {
        assertionFailure()
      }
    })
    self.stream.setLimit(lowWater: 0)
  }
}

// TODO We could test input and output, on the streams, and ensure that once the connection is closed, everything is closed as well.
// Create DispatchStreams, reader and writers that we can use for this scenarios.
extension BKInputStream: WriterTo {
  func writeTo(_ w: Writer) -> AnyPublisher<Int, Error> {
    let pub = PassthroughSubject<DispatchData, Error>()
    
    return pub.handleEvents(receiveRequest: { _ in
      self.stream.read(offset: 0, length: Int(UINT32_MAX), queue: self.queue) { (done, data, error) in
        if error == POSIXErrorCode.ECANCELED.rawValue {
          return
        }

        if error != 0 {
          pub.send(completion: .failure(BKStreamError.read))
          return
        }

        guard let data = data else {
          return assertionFailure()
        }

        let eof = done && data.count == 0
        guard !eof else {
          return pub.send(completion: .finished)
        }

        pub.send(data)

        // TODO Communicate EOFs to the other side of the pipe
        if done {
          return pub.send(completion: .finished)
        }
      }
    })
    .print()
    .flatMap { data in
      // TODO This may be one of those cases, where we actually care about the write
      // side moving things forward, instead of the read.
      return w.write(data, max: data.count)
    }.eraseToAnyPublisher()
  }
}
