import Foundation

// ───────── 정규식 도우미 ─────────

extension NSRegularExpression {
    convenience init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        try! self.init(pattern: pattern, options: options)
    }
}

extension String {
    var fullRange: NSRange { NSRange(startIndex..., in: self) }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func replacingRegex(_ re: NSRegularExpression, with template: String = "") -> String {
        re.stringByReplacingMatches(in: self, range: fullRange, withTemplate: template)
    }

    func matches(_ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: self, range: fullRange) != nil
    }

    /// 첫 번째 일치의 그룹들 (0 = 전체)
    func firstGroups(_ re: NSRegularExpression) -> [String?]? {
        guard let m = re.firstMatch(in: self, range: fullRange) else { return nil }
        return groups(of: m)
    }

    func allGroups(_ re: NSRegularExpression) -> [[String?]] {
        re.matches(in: self, range: fullRange).map { groups(of: $0) }
    }

    private func groups(of m: NSTextCheckingResult) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: self) else { return nil }
            return String(self[rr])
        }
    }
}

// ───────── JSON 도우미 ─────────

func dig(_ o: Any?, _ keys: Any...) -> Any? {
    var cur = o
    for k in keys {
        if let s = k as? String {
            cur = (cur as? [String: Any])?[s]
        } else if let i = k as? Int {
            guard let a = cur as? [Any], i >= 0, i < a.count else { return nil }
            cur = a[i]
        }
        if cur == nil || cur is NSNull { return nil }
    }
    return cur
}

func num(_ o: Any?) -> Double? {
    if let n = o as? NSNumber { return n.doubleValue }
    if let s = o as? String { return Double(s) }
    return nil
}

func str(_ o: Any?) -> String? {
    if let s = o as? String { return s }
    if let n = o as? NSNumber { return n.stringValue }
    return nil
}

func truthy(_ o: Any?) -> Bool {
    if let n = o as? NSNumber { return n.doubleValue != 0 }
    if let b = o as? Bool { return b }
    if let s = o as? String { return !s.isEmpty && s != "0" && s != "false" }
    return false
}

func makeURL(_ base: String, _ query: [(String, String)] = []) -> URL {
    var c = URLComponents(string: base)!
    if !query.isEmpty {
        c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // "+" 는 URLComponents 가 그대로 두므로 직접 바꿉니다.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    return c.url!
}

// ───────── 네트워크 ─────────

enum NetError: LocalizedError {
    case http(Int)
    case final(String)
    case bad(String)

    var errorDescription: String? {
        switch self {
        case .http(let c): return "HTTP \(c)"
        case .final(let m), .bad(let m): return m
        }
    }
}

func errorText(_ e: Error) -> String {
    if let l = e as? LocalizedError, let d = l.errorDescription { return d }
    if let u = e as? URLError {
        switch u.code {
        case .timedOut: return "응답 시간 초과"
        case .notConnectedToInternet: return "인터넷 연결 없음"
        default: return "연결 실패 (\(u.code.rawValue))"
        }
    }
    return e.localizedDescription
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static let appUA = "SpotifyPiP/1.0 (iOS)"

    /// 서버가 바쁘거나(429, 5xx) 연결이 끊기면 1.2초, 2.4초 쉬고 다시 시도합니다.
    /// 200 이면 본문, 4xx 면 nil("없음"), 계속 실패하면 오류를 던집니다.
    static func text(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> String? {
        var lastErr: Error = NetError.bad("요청 실패")
        for attempt in 0..<3 {
            if attempt > 0 {
                let ms = 1200.0 * pow(2.0, Double(attempt - 1)) + Double.random(in: 0...400)
                try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
            }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            req.setValue(appUA, forHTTPHeaderField: "User-Agent")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let text = String(data: data, encoding: .utf8) ?? ""
                if code == 200 { return text }
                if code == 429 || code >= 500 {
                    // SOAP 오류 응답은 다시 물어도 같습니다.
                    if text.contains("Fault>") { throw NetError.final("서버가 요청을 거절했습니다") }
                    lastErr = NetError.http(code)
                    continue
                }
                return nil
            } catch let e as NetError {
                if case .final = e { throw e }
                lastErr = e
            } catch {
                lastErr = error
            }
        }
        throw lastErr
    }

    static func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> Any? {
        guard let t = try await text(url, method: method, headers: headers, body: body) else { return nil }
        guard let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) else {
            throw NetError.bad("응답 형식이 올바르지 않습니다")
        }
        return o
    }
}

// ───────── 파일 위치 ─────────

enum Files {
    static var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
