import Foundation

struct LyricLine: Codable, Equatable, Sendable {
    var t: Int        // ms
    var text: String
}

enum LyricsStatus: String, Codable, Sendable {
    case loading, synced, plain, instrumental, notfound, error
}

struct LyricsResult: Codable, Equatable, Sendable {
    var status: LyricsStatus
    var lines: [LyricLine] = []
    var source: String? = nil
    var partial: Bool = false
    var detail: String? = nil
    var srcKey: String? = nil
    var savedAt: Double = 0
    var trackId: String? = nil
}

/// 가사 글자 다루기 (PC 오버레이의 lyrics.js 를 옮긴 것)
enum LyricsText {
    static let timeTag = NSRegularExpression(#"^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    static let wordTag = NSRegularExpression(#"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)
    static let br = NSRegularExpression(#"<br\s*/?>"#, .caseInsensitive)
    static let feat = NSRegularExpression(#"\s*[(\[](feat\.?|ft\.?|with)\s[^)\]]*[)\]]"#, .caseInsensitive)
    static let dashSuffix = NSRegularExpression(#"\s+-\s+.*(remaster|version|live|edit|mix|mono|stereo|ver\.).*$"#, .caseInsensitive)
    static let paren = NSRegularExpression(#"\s*[(\[（【<].*?[)\]）】>]"#)
    static let hangul = NSRegularExpression("[\u{AC00}-\u{D7A3}]")
    static let credit = NSRegularExpression(#"^\s*(作词|作曲|编曲|作詞|編曲|制作人|监制|和声|混音|录音|母带|吉他|贝斯|鼓|键盘|弦乐|出品|发行|OP|SP|词|曲|lyricist|lyrics|composer|composed|arranger|arranged|producer|produced|작사|작곡|편곡|프로듀서)\s*(by)?\s*[:：]"#, .caseInsensitive)
    static let artistSplit = NSRegularExpression(#",\s*|&|\s+x\s+"#, .caseInsensitive)

    static func parseLrc(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let text = lrc.replacingRegex(br, with: "\n")
        for raw in text.components(separatedBy: .newlines) {
            var rest = raw.trimmed
            var times: [Int] = []
            while let m = timeTag.firstMatch(in: rest, range: rest.fullRange),
                  let whole = Range(m.range, in: rest) {
                func g(_ i: Int) -> String {
                    let r = m.range(at: i)
                    guard r.location != NSNotFound, let rr = Range(r, in: rest) else { return "" }
                    return String(rest[rr])
                }
                let mm = Int(g(1)) ?? 0, ss = Int(g(2)) ?? 0
                let f = g(3)
                let fv = Int(f) ?? 0
                let frac = f.count == 1 ? fv * 100 : f.count == 2 ? fv * 10 : f.count == 3 ? fv : 0
                times.append(mm * 60000 + ss * 1000 + frac)
                rest = String(rest[whole.upperBound...])
            }
            if times.isEmpty { continue }
            let line = rest.replacingRegex(wordTag).trimmed
            for t in times { out.append(LyricLine(t: t, text: line)) }
        }
        return out.sorted { $0.t < $1.t }
    }

    static func cleanTitle(_ title: String) -> String {
        let t = title.replacingRegex(feat).replacingRegex(dashSuffix).trimmed
        return t.isEmpty ? title : t
    }

    /// 비교용: 괄호 안 내용과 띄어쓰기, 기호를 빼고 소문자로
    static func norm(_ s: String, keepParen: Bool = false) -> String {
        var t = s.precomposedStringWithCompatibilityMapping.lowercased()
        if !keepParen { t = t.replacingRegex(paren) }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: t.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
        return String(v)
    }

    static func titleMatch(_ cand: String, _ ours: String) -> Bool {
        for keep in [false, true] {
            let a = norm(cand, keepParen: keep), b = norm(ours, keepParen: keep)
            if a.isEmpty || b.isEmpty { continue }
            if a == b { return true }
            let lo = min(a.count, b.count), hi = max(a.count, b.count)
            if lo >= 2 && (a.contains(b) || b.contains(a)) && hi <= lo * 2 + 2 { return true }
        }
        return false
    }

    static func artistMatch(_ cand: String, _ ours: String) -> Bool {
        let c = norm(cand, keepParen: true)
        if c.isEmpty { return false }
        let parts = ours.replacingRegex(artistSplit, with: "\u{1}").components(separatedBy: "\u{1}")
        return parts.contains { a in
            let n = norm(a, keepParen: true)
            return n.count >= 2 && (c.contains(n) || n.contains(c))
        }
    }

    /// 같은 시각에 여러 줄이 있으면, 모두 같은 글자 종류면 이어 붙이고 섞여 있으면 첫 줄(원문)만 씁니다.
    static func mergeSameTime(_ lines: [LyricLine]) -> [LyricLine] {
        var out: [LyricLine] = []
        var i = 0
        while i < lines.count {
            var j = i
            var group: [String] = []
            while j < lines.count && lines[j].t == lines[i].t {
                if !lines[j].text.isEmpty { group.append(lines[j].text) }
                j += 1
            }
            var text = group.first ?? ""
            if group.count > 1 {
                let k = group[0].matches(hangul)
                text = group.allSatisfy({ $0.matches(hangul) == k }) ? group.joined(separator: " ") : group[0]
            }
            out.append(LyricLine(t: lines[i].t, text: text))
            i = j
        }
        return out
    }

    /// 쓸 만한 싱크 가사인지 (줄 수, 곡 길이와 맞는지)
    static func plausible(_ lines: [LyricLine], durationMs: Int) -> Bool {
        let timed = lines.filter { !$0.text.isEmpty }
        if timed.count < 3 { return false }
        if Set(timed.map { $0.t }).count < 3 { return false }
        if durationMs > 0, let last = timed.last?.t {
            if last > durationMs + 15000 { return false }
            if Double(last) < Double(durationMs) * 0.35 { return false }
        }
        return true
    }

    static func decodeXml(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        let re = NSRegularExpression("&#(x?)([0-9a-fA-F]+);", .caseInsensitive)
        let ns = t as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = !ns.substring(with: m.range(at: 1)).isEmpty
            let digits = ns.substring(with: m.range(at: 2))
            if let v = UInt32(digits, radix: hex ? 16 : 10), let sc = Unicode.Scalar(v) {
                out.unicodeScalars.append(sc)
            } else {
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escXml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func xmlTag(_ xml: String, _ name: String) -> String {
        let re = NSRegularExpression("<\(NSRegularExpression.escapedPattern(for: name))>([\\s\\S]*?)</\(NSRegularExpression.escapedPattern(for: name))>")
        guard let g = xml.firstGroups(re), let v = g[1] else { return "" }
        return decodeXml(v)
    }
}
