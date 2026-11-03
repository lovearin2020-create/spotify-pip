import SwiftUI
import Combine

/// 앱 전체를 묶는 곳: Spotify, 가사, PiP, 설정
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let spotify = SpotifyService()
    let lyrics = LyricsService()
    let pip = PiPManager()

    @Published private(set) var art: UIImage? = nil
    private var artURL: String? = nil
    private var bag = Set<AnyCancellable>()

    init() {
        lyrics.sources = { [unowned self] in self.settings.enabledSources }

        // 하위 객체가 바뀌면 화면도 새로 그립니다.
        for p in [settings.objectWillChange, spotify.objectWillChange, lyrics.objectWillChange, pip.objectWillChange] {
            p.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }

        spotify.$track
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.trackChanged(t) }
            .store(in: &bag)

        settings.$sources
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.lyrics.sourcesChanged() }
            .store(in: &bag)

        settings.$autoPiP
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.pip.setAutoStart(on) }
            .store(in: &bag)

        pip.state = { [unowned self] in self.renderState() }
        pip.onSetPlaying = { [unowned self] play in self.spotify.setPlaying(play) }
    }

    func start() {
        pip.setup(autoStart: settings.autoPiP)
        spotify.start()
    }

    private func trackChanged(_ t: Track?) {
        pip.playbackChanged(paused: !(t?.playing ?? false))
        if let t { lyrics.request(t) } else { lyrics.clear() }
        let url = t?.imageUrl
        if url != artURL {
            artURL = url
            art = nil
            guard let url, let u = URL(string: url) else { return }
            Task {
                guard let res = try? await HTTP.session.data(from: u), let img = UIImage(data: res.0) else { return }
                if self.artURL == url { self.art = img }
            }
        }
    }

    func renderState() -> RenderState {
        var notice: String? = nil
        if !spotify.loggedIn { notice = "앱에서 Spotify에 로그인해 주세요." }
        else if let l = spotify.limitText { notice = l }
        return RenderState(track: spotify.loggedIn ? spotify.track : nil, art: art, lyrics: lyrics.current,
                           theme: settings.theme, layout: settings.layout,
                           offsetMs: Int(settings.offsetMs), notice: notice)
    }

    var lyricsStatusText: String {
        guard let t = spotify.track else { return "" }
        guard let L = lyrics.current, L.trackId == t.id else { return "가사를 기다리고 있습니다." }
        let from = L.source.flatMap { Providers.names[$0] }.map { "\($0)에서 " } ?? ""
        var s: String
        switch L.status {
        case .loading: s = "가사를 찾고 있습니다."
        case .synced: s = "\(from)가사를 찾았습니다. (\(L.lines.count)줄)"
        case .plain: s = "\(from)시간 정보가 없는 가사만 찾아서 표시하지 않습니다."
        case .instrumental: s = "연주곡이라 가사가 없습니다."
        case .notfound: s = "켜 둔 검색처에서 이 곡의 가사를 찾지 못했습니다."
        case .error: s = "가사 서버에 연결하지 못했습니다."
        }
        if let d = L.detail, L.status != .synced { s += " (\(d))" }
        return s
    }
}
