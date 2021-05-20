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
import BlinkFiles
import FileProvider
import SSH

enum BlinkProtocol {
  case sshProtocol
  case localProtocol
}

class BlinkUtility {
  
  var enumeratedItemIdentifier: NSFileProviderItemIdentifier
  // TODO instance should be lazy loaded in a Factory pattern
  let localBlink = Local()
  // TODO instance should be lazy loaded in a Factory pattern
  let sshClient: () =  SSHInit()
  let path: String
  let domain: NSFileProviderDomain
  let proto: BlinkProtocol
  
  init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain) {

    self.enumeratedItemIdentifier = enumeratedItemIdentifier
    self.domain = domain
    
    let protoRaw = domain.identifier.rawValue
    //if ( protoRaw.hasPrefix("sftp")) {

      //Todo: We haven't initialise the translator yet
      self.path = "/"
      proto = .sshProtocol
//    } else if (protoRaw.hasPrefix("local")){
//      self.path = self.localBlink.current
//      proto = .localProtocol
//    } else {
//      self.path = self.localBlink.current
//      proto = .localProtocol
//    }
    
    // TODO The factory to instance an translators is the one that would have to care about how that is done for each of the
    // protocols. But once that is done, everything is a Translator. So the enumerator can be unique, we just need that
    // BlinkFilesFactory that instances the different protocols.
    // TODO The enumerator here also has access to the path for the domain, so we can take a look at that
    // and figure out where the relative path is.
    // TODO It looks like paths cannot be ssh:// as those would collide with file:// but we can definitely
    // do something like file://blinkfiles/ssh:host/path_to_file or whatever.
    
  }
  
  func enumerateLocalItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    /* TODO:
     - inspect the page to determine whether this is an initial or a follow-up request
     
     If this is an enumerator for a directory, the root container or all directories:
     - perform a server request to fetch directory contents
     If this is an enumerator for the active set:
     - perform a server request to update your local database
     - fetch the active set from your local database
     
     - inform the observer about the items returned by the server (possibly multiple times)
     - inform the observer that you are finished with this page
     */
    
    
    switch enumeratedItemIdentifier {
    case .rootContainer:

      if (proto == .localProtocol){
        blinkLocalWorker(observer: observer)
      }
      DispatchQueue.main.async {
        if (self.proto == .sshProtocol){
          self.blinkSSHWorker(observer: observer)
        }
      }
      
      return
    case .workingSet:
      return
    default:
      if (proto == .localProtocol){
        blinkLocalWorker(observer: observer)
      }
      DispatchQueue.main.async {
        if (self.proto == .sshProtocol){
        self.blinkSSHWorker(observer: observer)
      }
      }
      break
    }
  }

  private func blinkLocalWorker(observer: NSFileProviderEnumerationObserver) {
    var c: AnyCancellable? = nil
    c = localBlink.walkTo(path).flatMap { $0.directoryFilesAndAttributes() }
      .sink(receiveCompletion: { _ in
        c = nil
    }, receiveValue: { attrs in
      let curr = self.localBlink.current
      debugPrint("local blink current")
      debugPrint(curr)
      let items = attrs.map { blinkAttr -> FileProviderItem in
        let ref = BlinkItemReference(rootPath: curr,
                                     attributes: blinkAttr)
        return FileProviderItem(reference: ref)
      }
      observer.didEnumerate(items)
      observer.finishEnumerating(upTo: nil)

      })
  }

  private func blinkSSHWorker(observer: NSFileProviderEnumerationObserver) {
    var connection: SSHClient?
    var sftp: SFTPClient?
    
    var c: AnyCancellable? = nil
    c = SSHClient.dial("localhost", with: SSHClientConfig(user: "carloscabanero", authMethods: [AuthPassword(with: "asdfzxcv")], loggingVerbosity: .debug))
      .print("Dialing...")
      .flatMap() { conn -> AnyPublisher<SFTPClient, Error> in
        connection = conn
        return conn.requestSFTP()
      }.flatMap() { client -> AnyPublisher<Translator, Error> in
          sftp = client
          return client.walkTo(self.path)
      }
      .flatMap { $0.directoryFilesAndAttributes() }
      .sink(receiveCompletion: { completion in
        c  = nil
        connection = nil
        switch completion {
        case .finished:
          print("finished")
        case .failure(let error):
          print("failure")
        }
      }, receiveValue: { attrs in
        let curr = sftp!.current
        let items = attrs.map { blinkAttr -> FileProviderItem in
          let ref = BlinkItemReference(rootPath: curr,
                                       attributes: blinkAttr)
          return FileProviderItem(reference: ref)
        }
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
      })
  }

}

extension SSHClientConfig {
  static let testConfig = SSHClientConfig(
    user: Credentials.localHost.user,
    port: Credentials.port,
    authMethods: [
      AuthPassword(with: Credentials.localHost.password)
    ],
    loggingVerbosity: .debug
  )
}

extension SSHClient {
  static func dialWithTestConfig() -> AnyPublisher<SSHClient, Error> {
    dial(Credentials.localHost.host, with: .testConfig)
  }
}

struct Credentials {
  let user: String
  let password: String
  let host: String

  static let localHost = Credentials(user: "carloscabanero", password: "asdfzxcv", host: "localhost")
  static let port: String = "22"
}

