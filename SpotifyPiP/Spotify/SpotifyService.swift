import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

struct Track: Equatable, Sendable {
    var id: String
    var uri: String?
    var title: String
    var artist: String
    var album: String?
    var imageUrl: String?
    var durationMs: Int
    var progressMs: Int
    var playing: Bool
    var fetchedAt: Date

    /// 지금 시점의 재생 위치(ms)
    func progress(at now: Date = Date()) -> Int {
        let p = playing ? progressMs + Int(now.timeIntervalSince(fetchedAt) * 1000) : progressMs
        return max(0, durationMs > 0 ? min(durationMs, p) : p)
    }
}

// ───────── 키체인 (로그인 정보 저장) ─────────

enum Keychain {
    static let service = "com.eun.spotifypip"

    static func save(_ data: Data, key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

/// 로그인 창을 띄울 위치
final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: UIWindow
    init(window: UIWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

struct Tokens: Codable {
    var clientId: String
    var access: String?
    var refresh: String?
    var expiresAt: Double
}

// ───────── Spotify ─────────

@MainActor
final class SpotifyService: ObservableObject {
    static let redirectURI = "spotifypip://callback"
    static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"

    @Published private(set) var loggedIn = false
    @Published private(set) var message = "로그인되어 있지 않습니다."
    @Published private(set) var lastError: String? = nil
    @Published private(set) var track: Track? = nil
    @Published private(set) var limitText: String? = nil

    private var tokens: Tokens?
    private var authSession: ASWebAuthenticationSession?
    private var anchor: AuthAnchor?
    private var timer: Timer?
    private var nextPollAt = Date.distantPast
    private var polling = false
    private var anchorProgress: (id: String, progressMs: Int, fetchedAt: Date)? = nil
    private var limitedUntil: Double = UserDefaults.standard.double(forKey: "spotify.limitedUntil")
    private var limitedClient: String? = UserDefaults.standard.string(forKey: "spotify.limitedClient")

    // 재생 위치는 보정해서 이어 가므로 자주 물을 필요가 없습니다.
    private let pollPlaying: Double = 3
    private let pollIdle: Double = 6

    init() {
        if let d = Keychain.load("tokens"), let t = try? JSONDecoder().decode(Tokens.self, from: d), t.refresh != nil {
            tokens = t
            loggedIn = true
            message = "로그인되어 있습니다."
        }
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard loggedIn else { return }
        if isLimited {
            limitText = makeLimitText()
            return
        }
        limitText = nil
        if polling || Date() < nextPollAt { return }
        polling = true
        nextPollAt = Date().addingTimeInterval(pollPlaying)
        Task {
            await self.poll(retry: true)
            self.polling = false
        }
    }

    // ───────── 요청 한도 ─────────

    private var isLimited: Bool {
        limitedUntil > Date().timeIntervalSince1970 && tokens != nil && tokens?.clientId == limitedClient
    }

    private func setLimit(_ sec: Double) {
        limitedUntil = Date().timeIntervalSince1970 + max(5, sec)
        limitedClient = tokens?.clientId
        UserDefaults.standard.set(limitedUntil, forKey: "spotify.limitedUntil")
        UserDefaults.standard.set(limitedClient, forKey: "spotify.limitedClient")
        limitText = makeLimitText()
    }

    private func clearLimit() {
        guard limitedUntil > 0 else { return }
        limitedUntil = 0
        UserDefaults.standard.removeObject(forKey: "spotify.limitedUntil")
        limitText = nil
    }

    private func makeLimitText() -> String {
        let left = max(0, limitedUntil - Date().timeIntervalSince1970)
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        let when = f.string(from: Date(timeIntervalSince1970: limitedUntil))
        let min = max(1, Int((left / 60).rounded()))
        let rest = min >= 60 ? "\(min / 60)시간 \(min % 60)분" : left >= 60 ? "\(min)분" : "\(Int(ceil(left)))초"
        return "Spotify 요청 한도에 걸려서 \(when)까지 쉽니다. (\(rest) 남음)"
    }

    // ───────── 로그인 ─────────

    func login(clientId rawId: String) {
        let clientId = rawId.trimmed
        guard clientId.count >= 16 else {
            message = "Client ID를 먼저 입력해 주세요."
            return
        }
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = b64url(Data(bytes))
        let challenge = b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = b64url(Data(bytes.prefix(12)))
        let url = makeURL("https://accounts.spotify.com/authorize", [
            ("client_id", clientId), ("response_type", "code"), ("redirect_uri", Self.redirectURI),
            ("code_challenge_method", "S256"), ("code_challenge", challenge),
            ("scope", Self.scopes), ("state", state),
        ])
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }).first
                ?? UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first else { return }
        let anchor = AuthAnchor(window: window)
        self.anchor = anchor
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "spotifypip") { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }
                self.authSession = nil
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        self.message = "로그인을 취소했습니다."
                    } else {
                        self.message = "로그인하지 못했습니다. (\(error.localizedDescription))"
                    }
                    return
                }
                guard let callback, let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { return }
                let items = comps.queryItems ?? []
                if let err = items.first(where: { $0.name == "error" })?.value {
                    self.message = "Spotify가 로그인을 거절했습니다. (\(err))"
                    return
                }
                guard items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value else {
                    self.message = "로그인 응답이 올바르지 않습니다."
                    return
                }
                await self.exchange(code: code, verifier: verifier, clientId: clientId)
            }
        }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        message = "브라우저에서 Spotify 로그인을 진행해 주세요."
        session.start()
    }

    private func exchange(code: String, verifier: String, clientId: String) async {
        let json = await postToken([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", Self.redirectURI),
            ("client_id", clientId), ("code_verifier", verifier),
        ])
        guard let json, let access = str(json["access_token"]) else {
            if message.isEmpty { message = "토큰을 받지 못했습니다." }
            return
        }
        tokens = Tokens(clientId: clientId, access: access, refresh: str(json["refresh_token"]),
                        expiresAt: Date().timeIntervalSince1970 + (num(json["expires_in"]) ?? 3600))
        saveTokens()
        loggedIn = true
        message = "로그인되었습니다."
        nextPollAt = .distantPast
    }

    func logout() {
        tokens = nil
        Keychain.delete("tokens")
        loggedIn = false
        track = nil
        lastError = nil
        message = "로그아웃했습니다."
    }

    private func saveTokens() {
        if let t = tokens, let d = try? JSONEncoder().encode(t) { Keychain.save(d, key: "tokens") }
    }

    private func postToken(_ params: [(String, String)]) async -> [String: Any]? {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        req.httpBody = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        do {
            let (data, resp) = try await HTTP.session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if code == 200 { return j }
            let desc = str(j?["error_description"]) ?? str(j?["error"]) ?? "HTTP \(code)"
            message = "토큰 요청이 실패했습니다. (\(desc))"
            if code == 400, str(j?["error"]) == "invalid_grant" { logout(); message = "로그인이 만료되었습니다. 다시 로그인해 주세요." }
            return nil
        } catch {
            lastError = "네트워크에 연결하지 못했습니다. (\(errorText(error)))"
            return nil
        }
    }

    private func accessToken(force: Bool = false) async -> String? {
        guard var t = tokens, let refresh = t.refresh else { return nil }
        if !force, let a = t.access, Date().timeIntervalSince1970 < t.expiresAt - 60 { return a }
        guard let json = await postToken([("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", t.clientId)]),
              let access = str(json["access_token"]) else { return nil }
        t.access = access
        t.expiresAt = Date().timeIntervalSince1970 + (num(json["expires_in"]) ?? 3600)
        if let r = str(json["refresh_token"]) { t.refresh = r }
        tokens = t
        saveTokens()
        return access
    }

    // ───────── 지금 재생 중 ─────────

    private func poll(retry: Bool) async {
        guard let token = await accessToken() else { return }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=track,episode")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("ko-KR,ko;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        let sent = Date()
        let data: Data
        let resp: HTTPURLResponse
        do {
            let (d, r) = try await HTTP.session.data(for: req)
            data = d
            resp = r as! HTTPURLResponse
        } catch {
            lastError = "네트워크에 연결하지 못했습니다. (\(errorText(error)))"
            return
        }
        let now = Date()
        let mid = Date(timeIntervalSince1970: (sent.timeIntervalSince1970 + now.timeIntervalSince1970) / 2)
        switch resp.statusCode {
        case 200:
            lastError = nil
            clearLimit()
            var parsed = (try? JSONSerialization.jsonObject(with: data)).flatMap { Self.parseTrack($0, fetchedAt: mid) }
            smooth(&parsed)
            track = parsed
            nextPollAt = Date().addingTimeInterval(nextDelay(parsed))
        case 204:
            lastError = nil
            clearLimit()
            track = nil
            anchorProgress = nil
            nextPollAt = Date().addingTimeInterval(pollIdle)
        case 401:
            if retry, await accessToken(force: true) != nil { await poll(retry: false); return }
            lastError = "인증이 만료되었습니다. 다시 로그인해 주세요."
        case 403:
            lastError = "403 오류가 났습니다. 대시보드 User Management에 이 계정이 등록되어 있는지, 앱 소유자가 Premium인지 확인해 주세요."
            nextPollAt = Date().addingTimeInterval(30)
        case 429:
            let wait = Double(resp.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
            setLimit(wait)
        default:
            lastError = "Spotify가 오류를 돌려줬습니다. (HTTP \(resp.statusCode))"
            nextPollAt = Date().addingTimeInterval(10)
        }
    }

    /// 다음에 물어볼 때까지: 재생 중이면 3초, 곡이 곧 끝나면 끝난 직후에 한 번
    private func nextDelay(_ t: Track?) -> Double {
        guard let t, t.playing else { return pollIdle }
        if t.durationMs > 0 {
            let toEnd = Double(t.durationMs - t.progressMs) / 1000
            if toEnd > 0 && toEnd + 0.4 < pollPlaying { return max(1, toEnd + 0.4) }
        }
        return pollPlaying
    }

    /// Spotify 가 알려 주는 재생 위치는 0.5~2초 늦게, 매번 다르게 옵니다.
    /// 같은 곡을 듣는 동안에는 받은 값 중 가장 덜 늦은 값을 기준으로 이어 갑니다. 2.5초 넘게 뒤처지면 되감기로 봅니다.
    private func smooth(_ t: inout Track?) {
        guard var cur = t, cur.playing, cur.id != "ad" else { anchorProgress = nil; return }
        if let a = anchorProgress, a.id == cur.id {
            let est = Double(a.progressMs) + cur.fetchedAt.timeIntervalSince(a.fetchedAt) * 1000
            let diff = Double(cur.progressMs) - est
            if diff < 0 && diff > -2500 {
                cur.progressMs = min(cur.durationMs > 0 ? cur.durationMs : Int.max, Int(est.rounded()))
            }
        }
        anchorProgress = (cur.id, cur.progressMs, cur.fetchedAt)
        t = cur
    }

    static func parseTrack(_ root: Any, fetchedAt: Date) -> Track? {
        let playing = truthy(dig(root, "is_playing"))
        let progress = Int(num(dig(root, "progress_ms")) ?? 0)
        guard let item = dig(root, "item") as? [String: Any] else {
            if str(dig(root, "currently_playing_type")) == "ad" {
                return Track(id: "ad", uri: nil, title: "광고", artist: "Spotify", album: nil, imageUrl: nil,
                             durationMs: 0, progressMs: 0, playing: playing, fetchedAt: fetchedAt)
            }
            return nil
        }
        let type = str(item["type"]) ?? "track"
        var artist = ""
        var album: String? = nil
        var images: [[String: Any]] = []
        if type == "episode" {
            artist = str(dig(item, "show", "name")) ?? ""
            images = (item["images"] as? [[String: Any]]) ?? (dig(item, "show", "images") as? [[String: Any]]) ?? []
        } else {
            artist = ((item["artists"] as? [[String: Any]]) ?? []).compactMap { str($0["name"]) }.joined(separator: ", ")
            album = str(dig(item, "album", "name"))
            images = (dig(item, "album", "images") as? [[String: Any]]) ?? []
        }
        let sorted = images.sorted { (num($0["width"]) ?? 0) < (num($1["width"]) ?? 0) }
        let img = (sorted.first { (num($0["width"]) ?? 0) >= 200 } ?? sorted.last).flatMap { str($0["url"]) }
        let isLocal = truthy(item["is_local"])
        return Track(id: str(item["id"]) ?? str(item["name"]) ?? "unknown",
                     uri: type == "track" && !isLocal ? str(item["uri"]) : nil,
                     title: str(item["name"]) ?? "", artist: artist, album: album, imageUrl: img,
                     durationMs: Int(num(item["duration_ms"]) ?? 0), progressMs: progress,
                     playing: playing, fetchedAt: fetchedAt)
    }

    // ───────── 재생 조작 (PiP 창의 재생 버튼) ─────────

    func setPlaying(_ play: Bool) {
        guard var t = track else { return }
        // 화면에 바로 반영
        t.progressMs = t.progress()
        t.fetchedAt = Date()
        t.playing = play
        track = t
        anchorProgress = nil
        Task {
            guard let token = await accessToken() else { return }
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(play ? "play" : "pause")")!)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await HTTP.session.data(for: req)
            self.nextPollAt = Date().addingTimeInterval(0.8)
        }
    }

    private func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
