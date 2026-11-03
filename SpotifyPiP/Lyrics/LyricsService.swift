import Foundation

/// 곡이 바뀔 때마다 가사를 한 번만 받아오고, 기기에 저장해 둡니다.
@MainActor
final class LyricsService: ObservableObject {
    @Published private(set) var current: LyricsResult? = nil

    private var cache: [String: LyricsResult] = [:]
    private var requestedId: String? = nil
    private var lastTrack: Track? = nil
    private var errorCount = 0
    private var nextRetryAt = Date.distantPast
    private var inFlight = false
    private var saveScheduled = false
    var sources: () -> [String] = { Providers.order }

    private let notFoundTTL: Double = 3 * 24 * 3600
    private let partialTTL: Double = 30 * 60
    private let cacheMax = 800
    private var cacheURL: URL { Files.dir.appendingPathComponent("lyrics-cache.json") }

    init() {
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode([String: LyricsResult].self, from: d) {
            cache = c
        }
    }

    private var srcKey: String { Providers.order.filter { sources().contains($0) }.joined(separator: "+") }

    private func usable(_ v: LyricsResult?) -> Bool {
        guard let v else { return false }
        if v.status == .synced { return true }
        if v.srcKey != srcKey { return false }
        let age = Date().timeIntervalSince1970 - v.savedAt
        if v.partial { return age < partialTTL }
        if v.status == .notfound { return age < notFoundTTL }
        return true
    }

    func request(_ t: Track?, force: Bool = false) {
        guard let t, t.id != "ad" else { return }
        lastTrack = t
        if !force && t.id == requestedId {
            if let c = current, c.status == .error {
                if Date() < nextRetryAt || inFlight { return }
            } else if let c = current, c.partial {
                if usable(cache[t.id]) || inFlight { return }
            } else { return }
        } else if t.id != requestedId {
            errorCount = 0
            nextRetryAt = .distantPast
        }
        requestedId = t.id

        if !force, let cached = cache[t.id], usable(cached) {
            var c = cached
            c.trackId = t.id
            current = c
            return
        }
        if current?.trackId != t.id || current?.status != .error {
            current = LyricsResult(status: .loading, trackId: t.id)
        }
        let key = srcKey
        let srcs = sources()
        inFlight = true
        Task {
            var r = await Providers.fetch(t, sources: srcs)
            self.inFlight = false
            if r.status == .error {
                self.errorCount += 1
                let wait = min(300.0, 15.0 * pow(2, Double(self.errorCount - 1)))
                self.nextRetryAt = Date().addingTimeInterval(wait)
                r.detail = "\(r.detail ?? ""), \(Int(wait))초 뒤에 다시 시도합니다"
            } else {
                self.errorCount = 0
                r.srcKey = key
                r.savedAt = Date().timeIntervalSince1970
                self.cache[t.id] = r
                self.saveSoon()
            }
            r.trackId = t.id
            if self.requestedId == t.id { self.current = r }
        }
    }

    /// 지금 곡의 가사를 저장된 결과 없이 다시 찾습니다.
    func refresh() {
        guard let t = lastTrack else { return }
        cache[t.id] = nil
        saveSoon()
        errorCount = 0
        request(t, force: true)
    }

    /// 검색처 설정이 바뀌면, 싱크 가사를 못 찾은 곡은 다시 찾아봅니다.
    func sourcesChanged() {
        guard let t = lastTrack, t.id == requestedId, current?.status != .synced else { return }
        request(t, force: true)
    }

    func clear() {
        requestedId = nil
        current = nil
    }

    private func saveSoon() {
        if saveScheduled { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let keep = self.cache.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(self.cacheMax)
            let obj = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            if let d = try? JSONEncoder().encode(obj) { try? d.write(to: self.cacheURL, options: .atomic) }
        }
    }
}
