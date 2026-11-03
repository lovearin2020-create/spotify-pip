import SwiftUI
import UIKit

struct RGBA: Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a / 255
    }
    var ui: UIColor { UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
    var color: Color { Color(ui) }
    func with(alpha: CGFloat) -> UIColor { UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha) }

    static func lerp(_ x: RGBA, _ y: RGBA, _ k: CGFloat) -> UIColor {
        UIColor(red: (x.r + (y.r - x.r) * k) / 255, green: (x.g + (y.g - x.g) * k) / 255,
                blue: (x.b + (y.b - x.b) * k) / 255, alpha: x.a + (y.a - x.a) * k)
    }
}

/// PiP 창은 영상이라 투명 배경을 쓸 수 없어서, 불투명 테마만 있습니다.
struct Theme: Identifiable {
    let id: String
    let name: String
    let bg: RGBA, title: RGBA, artist: RGBA, bar: RGBA
    let current: RGBA, other: RGBA, box: RGBA
}

enum Themes {
    static let all: [Theme] = [
        Theme(id: "spotify", name: "Spotify 기본",
              bg: RGBA(18, 18, 18), title: RGBA(255, 255, 255), artist: RGBA(179, 179, 179), bar: RGBA(29, 185, 84),
              current: RGBA(255, 255, 255), other: RGBA(150, 150, 150), box: RGBA(29, 185, 84, 70)),
        Theme(id: "midnight", name: "미드나잇 블루",
              bg: RGBA(15, 23, 42), title: RGBA(241, 245, 249), artist: RGBA(148, 163, 184), bar: RGBA(96, 165, 250),
              current: RGBA(255, 255, 255), other: RGBA(120, 135, 160), box: RGBA(96, 165, 250, 70)),
        Theme(id: "gold", name: "다크 골드",
              bg: RGBA(1, 10, 19), title: RGBA(240, 230, 210), artist: RGBA(200, 170, 110), bar: RGBA(200, 170, 110),
              current: RGBA(240, 230, 210), other: RGBA(140, 135, 120), box: RGBA(200, 170, 110, 60)),
        Theme(id: "sakura", name: "벚꽃",
              bg: RGBA(40, 24, 32), title: RGBA(255, 240, 245), artist: RGBA(244, 183, 203), bar: RGBA(255, 128, 170),
              current: RGBA(255, 245, 250), other: RGBA(200, 150, 170), box: RGBA(255, 128, 170, 70)),
        Theme(id: "lavender", name: "라벤더",
              bg: RGBA(30, 24, 48), title: RGBA(245, 240, 255), artist: RGBA(190, 170, 230), bar: RGBA(167, 139, 250),
              current: RGBA(250, 245, 255), other: RGBA(160, 145, 200), box: RGBA(167, 139, 250, 70)),
        Theme(id: "sunset", name: "선셋",
              bg: RGBA(32, 20, 14), title: RGBA(255, 244, 230), artist: RGBA(240, 180, 140), bar: RGBA(255, 140, 66),
              current: RGBA(255, 248, 240), other: RGBA(200, 150, 120), box: RGBA(255, 140, 66, 70)),
        Theme(id: "mint", name: "민트",
              bg: RGBA(10, 40, 38), title: RGBA(230, 255, 250), artist: RGBA(140, 220, 200), bar: RGBA(52, 211, 153),
              current: RGBA(240, 255, 252), other: RGBA(120, 185, 170), box: RGBA(52, 211, 153, 65)),
        Theme(id: "neon", name: "네온",
              bg: RGBA(10, 10, 20), title: RGBA(240, 250, 255), artist: RGBA(255, 110, 210), bar: RGBA(0, 240, 255),
              current: RGBA(0, 240, 255), other: RGBA(220, 120, 200), box: RGBA(255, 64, 200, 60)),
        Theme(id: "white", name: "미니멀 화이트",
              bg: RGBA(250, 250, 250), title: RGBA(17, 17, 17), artist: RGBA(90, 90, 90), bar: RGBA(17, 17, 17),
              current: RGBA(17, 17, 17), other: RGBA(130, 130, 130), box: RGBA(0, 0, 0, 28)),
    ]
}

enum PiPLayout: String, CaseIterable, Identifiable {
    case full, lyrics, info
    var id: String { rawValue }
    var name: String {
        switch self {
        case .full: return "곡 정보 + 가사"
        case .lyrics: return "가사만"
        case .info: return "곡 정보만"
        }
    }
    /// PiP 창 비율은 이 크기를 따릅니다.
    var size: CGSize {
        switch self {
        case .full: return CGSize(width: 960, height: 540)
        case .lyrics: return CGSize(width: 960, height: 400)
        case .info: return CGSize(width: 960, height: 320)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var clientId: String { didSet { d.set(clientId, forKey: "clientId") } }
    @Published var themeId: String { didSet { d.set(themeId, forKey: "themeId") } }
    @Published var layout: PiPLayout { didSet { d.set(layout.rawValue, forKey: "layout") } }
    @Published var offsetMs: Double { didSet { d.set(offsetMs, forKey: "offsetMs") } }
    @Published var autoPiP: Bool { didSet { d.set(autoPiP, forKey: "autoPiP") } }
    @Published var sources: [String: Bool] { didSet { d.set(sources, forKey: "sources") } }

    init() {
        clientId = d.string(forKey: "clientId") ?? ""
        themeId = d.string(forKey: "themeId") ?? "spotify"
        layout = PiPLayout(rawValue: d.string(forKey: "layout") ?? "") ?? .full
        offsetMs = d.object(forKey: "offsetMs") as? Double ?? 0
        autoPiP = d.object(forKey: "autoPiP") as? Bool ?? true
        sources = (d.dictionary(forKey: "sources") as? [String: Bool]) ?? [:]
    }

    var theme: Theme { Themes.all.first { $0.id == themeId } ?? Themes.all[0] }
    var enabledSources: [String] { Providers.order.filter { sources[$0] ?? true } }

    func binding(for source: String) -> Binding<Bool> {
        Binding(get: { self.sources[source] ?? true }, set: { self.sources[source] = $0 })
    }
}
