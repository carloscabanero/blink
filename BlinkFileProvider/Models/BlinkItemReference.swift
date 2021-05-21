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
import FileProvider
import MobileCoreServices

import BlinkFiles

struct BlinkItemReference {
  private let urlRepresentation: URL
  var attributes: BlinkFiles.FileAttributes? = nil
  
  // TODO: Blink Translator Reference for real root path
  private var isRoot: Bool {
    return urlRepresentation.path == "/"
  }
  
  // No Blink File?
  private init(urlRepresentation: URL) {
    self.urlRepresentation = urlRepresentation
  }
  
  private init(urlRepresentation: URL, attributes: BlinkFiles.FileAttributes){
    self.init(urlRepresentation: urlRepresentation)
    self.attributes = attributes
  }
  
  // MARK: - Enumerator Entry Point:
  // objective is to convert to URL representation
  // file://path_to_domain/path_to_file_encoded/name
  // a Database model -> domain://root/path/name[.extension]
  init(rootPath: String, attributes: BlinkFiles.FileAttributes) {
    let type = attributes[.type] as? FileAttributeType
    let isAttrDirectory = type == .typeDirectory
    let filename = attributes[.name] as! String
    let nsRootPath = (rootPath as NSString).standardizingPath

    let pathComponents = nsRootPath.components(separatedBy: "/").filter {
      !$0.isEmpty
    } + [filename]
    
    var absolutePath = "/" + pathComponents.joined(separator: "/")

    if isAttrDirectory {
      absolutePath.append("/")
    }

    //take out spaces and characters
    absolutePath = absolutePath.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed
    ) ?? absolutePath

    self.init(urlRepresentation: URL(string: "blinkDomainReference://\(absolutePath)")!, attributes: attributes)
  }
  
  // MARK: - DB Query Entry Point:
  // The URL needs to be below the container.
  // https://developer.apple.com/documentation/fileprovider/nsfileproviderextension/1623481-urlforitemwithpersistentidentifi?language=objc
  // https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/2879513-documentstorageurl?language=objc
  //1.
  /*
   system provides the identifier passed to this method, and you return a FileProviderItem for that identifier.
   
   scheme blinkDomainReference://.
   
   You handle the root container identifier separately to ensure its URL path is properly set.

   For the other items, the URL representation is retrieved by converting the raw value of the identifier to base64-encoded data. The information in the URL comes from the network request that first enumerated the instance.
   */
  init?(itemIdentifier: NSFileProviderItemIdentifier) {
    
    // MARK: - Objective is to ???
    guard itemIdentifier != .rootContainer else {
      
      self.init(urlRepresentation: URL(string: "blinkDomainReference:///")!)
      return
      
    }
    
    guard let data = Data(base64Encoded: itemIdentifier.rawValue),
      let url = URL(dataRepresentation: data, relativeTo: nil) else {
        return nil
    }
    
    self.init(urlRepresentation: url)
  }


  var itemIdentifier: NSFileProviderItemIdentifier {
    if isRoot {
      return .rootContainer
    } else {
      return NSFileProviderItemIdentifier(
        rawValue: urlRepresentation.dataRepresentation.base64EncodedString()
      )
    }
  }

  var isDirectory: Bool {
    return urlRepresentation.hasDirectoryPath
  }

  var path: String {
    return urlRepresentation.path
  }

  var containingDirectory: String {
    return urlRepresentation.deletingLastPathComponent().path
  }

  var filename: String {
    return urlRepresentation.lastPathComponent
  }

  var typeIdentifier: String {
    guard let type = attributes?[.type] as? FileAttributeType else {
      return ""
    }
    if type == .typeDirectory {
      return kUTTypeFolder as String
    }
     
    let pathExtension = urlRepresentation.pathExtension
    let unmanaged = UTTypeCreatePreferredIdentifierForTag(
      kUTTagClassFilenameExtension,
      pathExtension as CFString,
      nil
    )
    let retained = unmanaged?.takeRetainedValue()

    return (retained as String?) ?? ""
  }

  var parentReference: BlinkItemReference? {
    guard !isRoot else {
      return nil
    }
    
    // convert between BlinkFile Attritubes and URL
    return BlinkItemReference(
      urlRepresentation: urlRepresentation.deletingLastPathComponent())
  }
}
