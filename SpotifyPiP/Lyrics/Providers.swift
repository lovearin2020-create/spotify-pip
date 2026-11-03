import Foundation

/// 가사 검색처 네 곳 (PC 오버레이 1.5.x 와 같은 방식)
enum Providers {
    static let order = ["musixmatch", "lrclib", "alsong", "netease"]
    static let names = ["musixmatch": "Musixmatch", "lrclib": "LRCLIB", "alsong": "알송", "netease": "NetEase"]
    static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

    static func run(_ key: String, _ t: Track) async throws -> LyricsResult? {
        switch key {
        case "musixmatch": return try await musixmatch(t)
        case "lrclib": return try await lrclib(t)
        case "alsong": return try await alsong(t)
        case "netease": return try await netease(t)
        default: return nil
        }
    }

    /// 켜진 곳에 동시에 묻고, 앞 순서(Musixmatch → LRCLIB → 알송 → NetEase)의 싱크 가사를 고릅니다.
    static func fetch(_ t: Track, sources: [String]) async -> LyricsResult {
        let list = order.filter { sources.contains($0) }
        if list.isEmpty { return LyricsResult(status: .notfound, detail: "켜진 가사 검색처가 없습니다") }

        var results: [String: Result<LyricsResult?, Error>] = [:]
        await withTaskGroup(of: (String, Result<LyricsResult?, Error>).self) { group in
            for k in list {
                group.addTask {
                    do { return (k, .success(try await run(k, t))) } catch { return (k, .failure(error)) }
                }
            }
            for await (k, r) in group { results[k] = r }
        }

        var failed: [(String, Error)] = []
        var found: [String: LyricsResult] = [:]
        for k in list {
            switch results[k] {
            case .success(let r?): found[k] = r
            case .failure(let e): failed.append((k, e))
            default: break
            }
        }
        for k in list {
            if let r = found[k], r.status == .synced {
                return LyricsResult(status: .synced, lines: r.lines, source: k)
            }
        }
        let failText = failed.map { "\(names[$0.0] ?? $0.0) \(errorText($0.1))" }.joined(separator: ", ")
        if failed.count == list.count { return LyricsResult(status: .error, detail: failText) }

        var base = LyricsResult(status: .notfound)
        if let k = list.first(where: { found[$0]?.status == .instrumental }) {
            base = LyricsResult(status: .instrumental, source: k)
        } else if let k = list.first(where: { found[$0]?.status == .plain }) {
            base = LyricsResult(status: .plain, source: k)
        }
        if !failed.isEmpty {
            base.partial = true
            base.detail = "\(failText), 30분 뒤에 다시 찾습니다"
        }
        return base
    }

    // ───────── LRCLIB ─────────

    static func lrclib(_ t: Track) async throws -> LyricsResult? {
        let base = "https://lrclib.net/api"
        let dur = Int((Double(t.durationMs) / 1000).rounded())
        let artist = t.artist.components(separatedBy: ", ").first ?? t.artist
        let clean = LyricsText.cleanTitle(t.title)

        var exact: [(String, String)] = [("track_name", t.title), ("artist_name", artist)]
        if let a = t.album, !a.isEmpty { exact.append(("album_name", a)) }
        if dur > 0 { exact.append(("duration", String(dur))) }
        let urls = [
            makeURL("\(base)/get", exact),
            makeURL("\(base)/search", [("track_name", clean), ("artist_name", artist)]),
            makeURL("\(base)/search", [("q", "\(clean) \(artist)")]),
            makeURL("\(base)/search", [("track_name", clean)]),
        ]

        func pick(_ arr: Any?) -> [String: Any]? {
            guard let a = arr as? [[String: Any]] else { return nil }
            var best: [String: Any]? = nil
            var bestScore = Double.infinity
            for o in a {
                var diff = 0.0
                if dur > 0 {
                    guard let d = num(o["duration"]) else { continue }
                    diff = abs(d - Double(dur)).rounded()
                    if diff > 3 { continue }
                }
                let score = diff + (str(o["syncedLyrics"]) != nil ? 0 : 100)
                if score < bestScore { bestScore = score; best = o }
            }
            return best
        }

        var other: LyricsResult? = nil
        var lastErr: Error? = nil
        for (i, u) in urls.enumerated() {
            let found: [String: Any]?
            do {
                let body = try await HTTP.json(u)
                found = i == 0 ? body as? [String: Any] : pick(body)
            } catch {
                lastErr = error
                continue
            }
            guard let f = found else { continue }
            if let s = str(f["syncedLyrics"]) {
                let lines = LyricsText.parseLrc(s)
                if !lines.isEmpty { return LyricsResult(status: .synced, lines: lines) }
            }
            if other == nil, str(f["plainLyrics"]) != nil { other = LyricsResult(status: .plain) }
            if other == nil, truthy(f["instrumental"]) { other = LyricsResult(status: .instrumental) }
        }
        if let o = other { return o }
        if let e = lastErr { throw e }
        return nil
    }

    // ───────── 알송 ─────────

    static let alsongURL = URL(string: "http://lyrics.alsong.co.kr/alsongwebservice/service1.asmx")!
    static let alsongKey = "7c2d15b8f51ac2f3b2a37d7a445c3158455defb8a58d621eb77a3ff8ae4921318e49cefe24e515f79892a4c29c9a3e204358698c1cfe79c151c04f9561e945096ccd1d1c0a8d8f265a2f3fa7995939b21d8f663b246bbc433c7589da7e68047524b80e16f9671b6ea0faaf9d6cde1b7dbcf1b89aa8a1d67a8bbc566664342e12"
    static let soapHead = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:SOAP-ENC=\"http://www.w3.org/2003/05/soap-encoding\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:ns2=\"ALSongWebServer/Service1Soap\" xmlns:ns1=\"ALSongWebServer\" xmlns:ns3=\"ALSongWebServer/Service1Soap12\"><SOAP-ENV:Body>"
    static let soapTail = "</SOAP-ENV:Body></SOAP-ENV:Envelope>"
    static let alsongItem = NSRegularExpression("<ST_SEARCHLYRIC_LIST>([\\s\\S]*?)</ST_SEARCHLYRIC_LIST>")

    static func alsongCall(_ body: String) async throws -> String? {
        try await HTTP.text(alsongURL, method: "POST",
                            headers: ["Content-Type": "application/soap+xml; charset=utf-8"],
                            body: (soapHead + body + soapTail).data(using: .utf8))
    }

    struct AlsongItem { let id: String; let title: String; let artist: String }

    static func alsongSearch(_ title: String, _ artist: String) async throws -> [AlsongItem] {
        let body = "<ns1:GetResembleLyricList2><ns1:encData>\(alsongKey)</ns1:encData>"
            + "<ns1:title>\(LyricsText.escXml(title))</ns1:title><ns1:artist>\(LyricsText.escXml(artist))</ns1:artist>"
            + "<ns1:pageNo>1</ns1:pageNo></ns1:GetResembleLyricList2>"
        guard let xml = try await alsongCall(body) else { return [] }
        return xml.allGroups(alsongItem).compactMap { g in
            guard let block = g[1] else { return nil }
            let id = LyricsText.xmlTag(block, "lyricID")
            if id.isEmpty { return nil }
            return AlsongItem(id: id, title: LyricsText.xmlTag(block, "title"), artist: LyricsText.xmlTag(block, "artist"))
        }
    }

    static func alsongLyric(_ id: String) async throws -> [LyricLine] {
        let body = "<ns1:GetLyricByID2><ns1:encData>\(alsongKey)</ns1:encData>"
            + "<ns1:lyricID>\(LyricsText.escXml(id))</ns1:lyricID></ns1:GetLyricByID2>"
        guard let xml = try await alsongCall(body) else { return [] }
        var output = LyricsText.xmlTag(xml, "output")
        if output.isEmpty { output = xml }
        // 가사 안의 줄바꿈은 &lt;br&gt; 로 한 번 더 감싸져 있는 경우가 있어서 두 번 풉니다.
        let lyric = LyricsText.decodeXml(LyricsText.xmlTag(output, "lyric"))
        // 0:00 줄은 보통 제목, 가수, 등록자 정보라서 뺍니다.
        let lines = LyricsText.parseLrc(lyric).filter { $0.t > 0 && !$0.text.matches(LyricsText.credit) }
        return LyricsText.mergeSameTime(lines)
    }

    static func alsong(_ t: Track) async throws -> LyricsResult? {
        let clean = LyricsText.cleanTitle(t.title)
        let first = t.artist.components(separatedBy: ", ").first ?? t.artist
        // 제목과 가수를 반대로 넣어야 답하는 경우가 있어서 마지막에 한 번 바꿔서 물어봅니다.
        let steps: [(String, String)] = [(clean, first), (clean, ""), (first, clean)]
        var seen = Set<String>()
        var tried = 0
        var lastErr: Error? = nil
        var answered = false
        outer: for (title, artist) in steps {
            let list: [AlsongItem]
            do {
                list = try await alsongSearch(title, artist)
                answered = true
            } catch {
                lastErr = error
                if case NetError.final = error { break }
                continue
            }
            let cands = list
                .filter { !seen.contains($0.id) && LyricsText.titleMatch($0.title, clean) }
                .map { ($0, LyricsText.artistMatch($0.artist, t.artist) ? 0 : 1) }
                .sorted { $0.1 < $1.1 }
            for (c, score) in cands {
                if tried >= 4 { break outer }
                seen.insert(c.id)
                tried += 1
                let lines: [LyricLine]
                do { lines = try await alsongLyric(c.id) } catch { lastErr = error; continue }
                // 가수가 안 맞는 후보는 곡 길이까지 맞을 때만 씁니다.
                if LyricsText.plausible(lines, durationMs: t.durationMs) && (score == 0 || t.durationMs > 0) {
                    return LyricsResult(status: .synced, lines: lines)
                }
            }
            if tried >= 4 { break }
        }
        if !answered, let e = lastErr { throw e }
        return nil
    }

    // ───────── NetEase ─────────

    static let neteaseHeaders = [
        "User-Agent": browserUA,
        "Referer": "https://music.163.com/",
        "Cookie": "os=pc; appver=2.10.13; NMTID=00OAVK3xqDG726ITU6jopU6jF2yMk0AAAGCO8l1BA; _ntes_nuid=0db6667097883aa9596ecfe7f188c3ec",
    ]

    static func netease(_ t: Track) async throws -> LyricsResult? {
        let clean = LyricsText.cleanTitle(t.title)
        let first = t.artist.components(separatedBy: ", ").first ?? t.artist
        let durMs = t.durationMs
        var answered = false
        var lastErr: Error? = nil
        var seen = Set<String>()
        for q in ["\(clean) \(first)", clean] {
            let body: Any?
            do {
                body = try await HTTP.json(makeURL("https://music.163.com/api/search/pc",
                                                   [("s", q), ("type", "1"), ("limit", "15"), ("offset", "0")]),
                                           headers: neteaseHeaders)
                answered = true
            } catch {
                lastErr = error
                continue
            }
            let songs = dig(body, "result", "songs") as? [[String: Any]] ?? []
            var cands: [(id: String, score: Int)] = []
            for x in songs {
                guard let id = str(x["id"]), !seen.contains(id) else { continue }
                var names = [str(x["name"]) ?? ""]
                names += (x["alias"] as? [String]) ?? []
                names += (x["transNames"] as? [String]) ?? []
                let arts = ((x["artists"] ?? x["ar"]) as? [[String: Any]] ?? []).compactMap { str($0["name"]) }.joined(separator: ", ")
                let dur = Int(num(x["duration"]) ?? num(x["dt"]) ?? 0)
                let durOk = durMs == 0 || dur == 0 || abs(dur - durMs) <= 4000
                let ok = names.contains { LyricsText.titleMatch($0, clean) } && durOk
                let score = LyricsText.artistMatch(arts, t.artist) ? 0 : 1
                if ok && (score == 0 || (durMs > 0 && dur > 0)) { cands.append((id, score)) }
            }
            cands.sort { $0.score < $1.score }
            for c in cands.prefix(3) {
                seen.insert(c.id)
                let lj: Any?
                do {
                    lj = try await HTTP.json(makeURL("https://music.163.com/api/song/lyric",
                                                     [("id", c.id), ("lv", "1"), ("tv", "-1")]),
                                             headers: neteaseHeaders)
                } catch { lastErr = error; continue }
                guard let j = lj as? [String: Any] else { continue }
                if truthy(j["nolyric"]) || truthy(j["pureMusic"]) { return LyricsResult(status: .instrumental) }
                let raw = str(dig(j, "lrc", "lyric")) ?? ""
                let lines = LyricsText.parseLrc(raw).filter { !$0.text.matches(LyricsText.credit) && !$0.text.hasPrefix("{") }
                if LyricsText.plausible(lines, durationMs: durMs) { return LyricsResult(status: .synced, lines: lines) }
                if !raw.trimmed.isEmpty { return LyricsResult(status: .plain) }
            }
        }
        if !answered, let e = lastErr { throw e }
        return nil
    }

    // ───────── Musixmatch ─────────

    static let mxmBase = "https://apic-desktop.musixmatch.com/ws/1.1"
    static let mxmApp = "web-desktop-app-v1.0"
    static let mxmHeaders = ["User-Agent": browserUA, "Cookie": "x-mxm-token-guid="]

    static func musixmatch(_ t: Track) async throws -> LyricsResult? {
        let durSec = Int((Double(t.durationMs) / 1000).rounded())
        for _ in 0..<2 {
            let token = try await MxmToken.shared.get()
            var q: [(String, String)] = [
                ("format", "json"), ("namespace", "lyrics_richsynched"), ("subtitle_format", "mxm"),
                ("app_id", mxmApp),
                ("q_track", t.title),
                ("q_artist", t.artist.components(separatedBy: ", ").first ?? t.artist),
                ("q_artists", t.artist),
                ("q_album", t.album ?? ""),
                ("q_duration", durSec > 0 ? String(durSec) : ""),
                ("f_subtitle_length", durSec > 0 ? String(durSec) : ""),
                ("usertoken", token),
                ("t", String(Int(Date().timeIntervalSince1970 * 1000))),
            ]
            // Spotify 곡 ID 를 같이 보내면 Musixmatch 가 정확히 같은 곡을 찾아 줍니다.
            if let uri = t.uri { q.append(("track_spotify_id", uri)) }
            guard let j = try await HTTP.json(makeURL("\(mxmBase)/macro.subtitles.get", q), headers: mxmHeaders) else { return nil }
            let top = Int(num(dig(j, "message", "header", "status_code")) ?? 0)
            if top == 401 { await MxmToken.shared.drop(); continue }
            if top != 0 && top != 200 { throw NetError.http(top) }
            guard let calls = dig(j, "message", "body", "macro_calls") else { return nil }

            let mCode = Int(num(dig(calls, "matcher.track.get", "message", "header", "status_code")) ?? 0)
            if mCode == 401 { await MxmToken.shared.drop(); continue }
            if mCode != 200 { return nil }

            let lyrics = dig(calls, "track.lyrics.get", "message", "body", "lyrics")
            if truthy(dig(lyrics, "restricted")) { return nil } // 저작권 때문에 막힌 곡
            if truthy(dig(calls, "matcher.track.get", "message", "body", "track", "instrumental")) || truthy(dig(lyrics, "instrumental")) {
                return LyricsResult(status: .instrumental)
            }
            let subCode = Int(num(dig(calls, "track.subtitles.get", "message", "header", "status_code")) ?? 0)
            if subCode == 200, let body = str(dig(calls, "track.subtitles.get", "message", "body", "subtitle_list", 0, "subtitle", "subtitle_body")) {
                let lines = parseMxm(body)
                if LyricsText.plausible(lines, durationMs: t.durationMs) { return LyricsResult(status: .synced, lines: lines) }
            }
            if str(dig(lyrics, "lyrics_body")) != nil { return LyricsResult(status: .plain) }
            return nil
        }
        throw NetError.bad("토큰이 계속 거절됩니다")
    }

    static func parseMxm(_ body: String) -> [LyricLine] {
        let s = body.trimmed
        if s.hasPrefix("["), !s.hasPrefix("[0"), let d = s.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            return arr.map { LyricLine(t: Int(((num(dig($0, "time", "total")) ?? 0) * 1000).rounded()), text: (str($0["text"]) ?? "").trimmed) }
                .sorted { $0.t < $1.t }
        }
        return LyricsText.parseLrc(s)
    }
}

/// Musixmatch 임시 토큰 (6시간까지 다시 쓰고, 발급이 막히면 1분, 2분, 4분 … 최대 30분 쉽니다)
actor MxmToken {
    static let shared = MxmToken()
    private let maxAge: Double = 6 * 3600
    private var token: String? = UserDefaults.standard.string(forKey: "mxm.token")
    private var savedAt: Double = UserDefaults.standard.double(forKey: "mxm.savedAt")
    private var blockedUntil: Double = 0
    private var blockCount = 0
    private var pending: Task<String, Error>? = nil

    func drop() {
        token = nil
        savedAt = 0
        UserDefaults.standard.removeObject(forKey: "mxm.token")
    }

    func get() async throws -> String {
        let now = Date().timeIntervalSince1970
        if let t = token, now - savedAt < maxAge { return t }
        if now < blockedUntil {
            throw NetError.bad("요청이 많아 잠시 막혔습니다 (\(Int(ceil(blockedUntil - now)))초 뒤 다시 시도)")
        }
        if let p = pending { return try await p.value }
        let task = Task<String, Error> {
            let url = makeURL("\(Providers.mxmBase)/token.get",
                              [("app_id", Providers.mxmApp), ("user_language", "ko"), ("t", String(Int(now * 1000)))])
            let j = try await HTTP.json(url, headers: Providers.mxmHeaders)
            let code = Int(num(dig(j, "message", "header", "status_code")) ?? 0)
            guard code == 200, let tok = str(dig(j, "message", "body", "user_token")), !tok.hasPrefix("UpgradeOnly") else {
                throw NetError.bad(code != 0 ? "토큰을 받지 못했습니다 (\(code))" : "토큰을 받지 못했습니다")
            }
            return tok
        }
        pending = task
        defer { pending = nil }
        do {
            let tok = try await task.value
            blockCount = 0
            token = tok
            savedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(tok, forKey: "mxm.token")
            UserDefaults.standard.set(savedAt, forKey: "mxm.savedAt")
            return tok
        } catch {
            blockCount += 1
            blockedUntil = Date().timeIntervalSince1970 + min(1800, 60 * pow(2, Double(blockCount - 1)))
            throw error
        }
    }
}
