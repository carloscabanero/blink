import Foundation

/// Platform-neutral v1 manifest. Shared manifest format used by Blink and Wink.
struct PluginManifest: Decodable {
  let manifestVersion: Int
  let id: String
  let name: String
  let version: String
  let entry: String
  let permissions: [String]
  /// Shell commands that open the app (Blink). Optional.
  let commands: [String]?
}

struct PluginPackage {
  let root: URL
  let manifest: PluginManifest

  init(root: URL) throws {
    self.root = root.resolvingSymlinksInPath().standardizedFileURL
    let manifestURL = self.root.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    guard data.count <= 65536 else { throw Failure.invalid("Manifest too large") }
    manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    // Accept portable declarations independently of which capabilities Blink grants.
    guard manifest.manifestVersion == 1,
          manifest.id.range(of: "^[a-z][a-z0-9]*(\\.[a-z0-9][a-z0-9-]*)+$", options: .regularExpression) != nil,
          !manifest.name.isEmpty, manifest.name.count <= 100, !manifest.version.isEmpty,
          Set(manifest.permissions).isSubset(of: ["storage", "database", "spotify"]),
          manifest.entry.hasSuffix(".html") else { throw Failure.invalid("Unsupported manifest") }
    let commands = manifest.commands ?? []
    guard commands.count <= 4, Set(commands).count == commands.count,
          commands.allSatisfy({ $0.range(of: "^[a-z][a-z0-9-]{1,31}$", options: .regularExpression) != nil }) else {
      throw Failure.invalid("Commands must be 2–32 lowercase letters, digits or dashes, at most four")
    }
    _ = try asset(manifest.entry)
  }

  func asset(_ path: String) throws -> URL {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
          !path.split(separator: "/").contains("..") else { throw Failure.invalid("Invalid asset path") }
    let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
    guard url.path.hasPrefix(root.path + "/"),
          (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
      throw Failure.invalid("Asset outside package or missing")
    }
    return url
  }

  enum Failure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
  }
}
