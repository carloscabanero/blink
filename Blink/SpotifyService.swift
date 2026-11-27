// Adapted from Wink’s Spotify service (GPL-3.0): https://github.com/myneid/wink
import UIKit
import SafariServices
import CryptoKit
import Network
import Security

/// Spotify Connect credentials stay native; the web app never receives OAuth tokens.
@MainActor final class SpotifyService {
  static let shared = SpotifyService()
  static let redirect = "http://127.0.0.1:43821/callback"
  private let session = URLSession(configuration: .ephemeral)
  private var pending: SpotifyCallback?
  private var credentials: [String: Any] = [:]
  private let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "org.blink.spotify.oauth", kSecAttrAccount as String: "spotify"]

  init() {
    var query = key; query[kSecReturnData as String] = true
    var result: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
       let data = result as? Data, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { credentials = value }
  }
  private func save() throws {
    let data = try JSONSerialization.data(withJSONObject: credentials)
    let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = key; item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure("Cannot save Spotify credentials in Keychain") }; return
    }
    guard status == errSecSuccess else { throw failure("Keychain is unavailable") }
  }
  private func failure(_ text: String) -> Error { PluginPackage.Failure.invalid(text) }
  func cancelLogin() { pending?.finish(.failure(failure("Login cancelled"))); pending = nil }
  func call(_ method: String, _ args: [String: Any], presentingFrom presenter: UIViewController?) async throws -> Any {
    switch method {
    case "spotify.status": return ["connected": credentials["refresh_token"] != nil, "redirectURI": Self.redirect]
    case "spotify.logout":
      cancelLogin()
      let status = SecItemDelete(key as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("Cannot remove Spotify credentials from Keychain") }
      credentials = [:]; return true
    case "spotify.login":
      guard pending == nil else { throw failure("Login already in progress") }
      guard let client = args["clientID"] as? String, client.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { throw failure("Enter a Spotify developer client ID (32 hex characters)") }
      let verifier = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      let state = UUID().uuidString
      let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
      var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
      url.queryItems = ["client_id": client, "response_type": "code", "redirect_uri": Self.redirect,
        "state": state, "code_challenge_method": "S256", "code_challenge": challenge,
        "scope": "user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read playlist-read-private playlist-read-collaborative"].map { URLQueryItem(name: $0.key, value: $0.value) }
      guard let presenter else { throw failure("Spotify login needs an active window") }
      let callback = SpotifyCallback(state: state); pending = callback
      defer { pending = nil }
      let code = try await callback.authorize(url.url!, from: presenter)
      var token = try await exchange(["grant_type": "authorization_code", "client_id": client, "code": code, "code_verifier": verifier, "redirect_uri": Self.redirect])
      token["client_id"] = client; credentials = token; try save(); return true
    case "spotify.request":
      guard let path = args["path"] as? String, let verb = args["verb"] as? String,
            Self.allowed(path: path, verb: verb) else { throw failure("Unsupported Spotify operation") }
      let token = try await accessToken()
      var url = URLComponents(string: "https://api.spotify.com/v1" + path)!
      if let query = args["query"] as? [String: String] { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
      var request = URLRequest(url: url.url!); request.httpMethod = verb
      request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
      if let body = args["body"] { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw failure("Invalid Spotify response") }
      guard (200..<300).contains(http.statusCode) else {
        if http.statusCode == 401 { credentials["expires_at"] = 0 }
        throw failure("Spotify HTTP \(http.statusCode). \(http.statusCode == 403 ? "Check account approval, scopes and Premium eligibility." : http.statusCode == 429 ? "Rate limited; retry after \(http.value(forHTTPHeaderField: "Retry-After") ?? "a few") seconds." : "Open Spotify on a device, or reconnect your account.")")
      }
      return data.isEmpty ? NSNull() : try JSONSerialization.jsonObject(with: data)
    case "spotify.artwork":
      guard let raw = args["url"] as? String, let url = URL(string: raw), url.scheme == "https", url.host == "i.scdn.co", url.user == nil, url.password == nil, url.port == nil else { throw failure("Invalid artwork URL") }
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "i.scdn.co", data.count <= 4 * 1024 * 1024, ["image/jpeg", "image/png"].contains(http.mimeType ?? "") else { throw failure("Artwork unavailable") }
      return "data:\(http.mimeType!);base64," + data.base64EncodedString()
    default: throw failure("Unsupported Spotify method")
    }
  }
  static func allowed(path: String, verb: String) -> Bool {
    let reads = ["/me", "/me/player", "/me/player/devices", "/me/player/queue", "/me/tracks", "/me/playlists", "/search"]
    if verb == "GET" { return reads.contains(path) || path.range(of: "^/(playlists/[A-Za-z0-9]+/(items|tracks)|artists/[A-Za-z0-9]+/albums|albums/[A-Za-z0-9]+/tracks)$", options: .regularExpression) != nil }
    if verb == "POST" { return ["/me/player/next", "/me/player/previous", "/me/player/queue"].contains(path) }
    return verb == "PUT" && ["/me/player", "/me/player/play", "/me/player/pause", "/me/player/seek", "/me/player/volume", "/me/player/repeat", "/me/player/shuffle"].contains(path)
  }
  private func accessToken() async throws -> String {
    if let expires = credentials["expires_at"] as? Double, expires > Date().timeIntervalSince1970 + 60, let access = credentials["access_token"] as? String { return access }
    guard let refresh = credentials["refresh_token"] as? String, let client = credentials["client_id"] as? String else { throw failure("Connect to Spotify first") }
    let token = try await exchange(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client])
    credentials.merge(token) { _, new in new }; try save()
    guard let access = credentials["access_token"] as? String else { throw failure("Missing access token") }; return access
  }
  private func exchange(_ fields: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var form = URLComponents(); form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
    request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, var token = try JSONSerialization.jsonObject(with: data) as? [String: Any], token["access_token"] is String else { throw failure("Spotify token exchange failed; verify the client ID and registered redirect URI") }
    token["expires_at"] = Date().timeIntervalSince1970 + (token["expires_in"] as? Double ?? 3600)
    return token
  }
}

/// Short-lived, IPv4 loopback-only OAuth callback; no LAN listener or custom URL scheme.
// All mutable callback state and NW callbacks are confined to DispatchQueue.main.
final class SpotifyCallback: NSObject, SFSafariViewControllerDelegate, @unchecked Sendable {
  static func validate(_ target: String, state: String) -> (valid: Bool, code: String?) {
    guard target.hasPrefix("/callback?"),
          let parsed = URLComponents(string: "http://127.0.0.1" + target), parsed.path == "/callback" else { return (false, nil) }
    let values = parsed.queryItems ?? []
    guard values.filter({ $0.name == "state" }).count == 1,
          values.first(where: { $0.name == "state" })?.value == state,
          values.filter({ $0.name == "code" }).count <= 1 else { return (false, nil) }
    return (true, values.first(where: { $0.name == "code" })?.value)
  }
  private let state: String
  private var listener: NWListener?
  private var continuation: CheckedContinuation<String, Error>?
  private var timer: DispatchWorkItem?
  private weak var browser: SFSafariViewController?
  init(state: String) { self.state = state }

  func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    browser = nil
    finish(.failure(PluginPackage.Failure.invalid("Spotify login cancelled")))
  }
  @MainActor func authorize(_ url: URL, from presenter: UIViewController) async throws -> String {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43821)
    let server = try NWListener(using: parameters); listener = server
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      server.stateUpdateHandler = { [weak self] status in
        guard let self = self else { return }
        switch status {
        case .ready:
          MainActor.assumeIsolated {
            guard self.continuation != nil else { return }
            let browser = SFSafariViewController(url: url)
            browser.delegate = self
            self.browser = browser
            presenter.present(browser, animated: true)
          }
        case .failed: self.finish(.failure(PluginPackage.Failure.invalid("Cannot listen on OAuth port 43821")))
        default: break
        }
      }
      server.newConnectionHandler = { [weak self] connection in
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
          guard let self = self else { connection.cancel(); return }
          let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
          let parts = line.split(separator: " ")
          let target = parts.count == 3 && parts[0] == "GET" ? String(parts[1]) : ""
          let (valid, code) = Self.validate(target, state: self.state)
          let response = valid ? "Spotify login received. Return to Blink." : "Invalid callback. Return to your Spotify login."
          let bytes = Data("HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: \(response.utf8.count)\r\n\r\n\(response)".utf8)
          connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()
            if valid { self.finish(code.map { .success($0) } ?? .failure(PluginPackage.Failure.invalid("Spotify login denied"))) }
          })
        }
      }
      let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(PluginPackage.Failure.invalid("Spotify login timed out"))) }
      timer = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
      server.start(queue: .main)
    }
  }
  func finish(_ result: Result<String, Error>) {
    guard let continuation = continuation else { return }
    self.continuation = nil; timer?.cancel(); listener?.cancel(); listener = nil
    MainActor.assumeIsolated { browser?.dismiss(animated: true) }
    browser = nil
    continuation.resume(with: result)
  }
}
