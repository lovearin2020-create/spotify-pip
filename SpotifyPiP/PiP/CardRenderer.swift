import UIKit
import QuartzCore

/// PiP 창 한 장면을 그리는 데 필요한 값
struct RenderState {
    var track: Track?
    var art: UIImage?
    var lyrics: LyricsResult?
    var theme: Theme
    var layout: PiPLayout
    var offsetMs: Int
    var notice: String?          // 로그인 필요, 요청 한도 등
}

/// 곡 정보 카드와 가사 세 줄을 그립니다. (PC 오버레이와 같은 모양)
final class CardRenderer {
    private var curIdx = -999
    private var prevIdx = -999
    private var changeAt: CFTimeInterval = 0
    private var trackId: String? = nil
    private let animDur: CFTimeInterval = 0.45
    private let leadMs = 150     // 줄 바뀜 애니메이션 시작을 조금 앞당김

    /// 지금 애니메이션 중이면 true (프레임을 더 자주 그림)
    private(set) var animating = false

    func draw(_ s: RenderState, size: CGSize) {
        let th = s.theme
        th.bg.ui.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        guard let t = s.track else {
            drawCentered(s.notice ?? "재생 중인 곡이 없습니다.", font: .systemFont(ofSize: 34, weight: .semibold),
                         color: th.artist.ui, center: CGPoint(x: size.width / 2, y: size.height / 2), maxWidth: size.width - 80)
            animating = false
            return
        }
        let now = Date()
        let progress = t.progress(at: now)

        switch s.layout {
        case .full:
            drawInfo(s, t, progress: progress, rect: CGRect(x: 34, y: 30, width: size.width - 68, height: 150), artSize: 150, titleSize: 40, artistSize: 30)
            drawLyrics(s, t, progress: progress, rect: CGRect(x: 24, y: 200, width: size.width - 48, height: size.height - 214), big: 46, small: 30, spacing: 96)
        case .lyrics:
            drawLyrics(s, t, progress: progress, rect: CGRect(x: 24, y: 12, width: size.width - 48, height: size.height - 24), big: 54, small: 34, spacing: 118)
        case .info:
            drawInfo(s, t, progress: progress, rect: CGRect(x: 34, y: 34, width: size.width - 68, height: size.height - 68), artSize: size.height - 68, titleSize: 52, artistSize: 38)
            animating = false
        }

        if let n = s.notice {
            let f = UIFont.systemFont(ofSize: 22, weight: .semibold)
            let w = min(size.width - 40, (n as NSString).size(withAttributes: [.font: f]).width + 28)
            let r = CGRect(x: (size.width - w) / 2, y: size.height - 46, width: w, height: 36)
            UIColor(white: 0, alpha: 0.6).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 10).fill()
            drawCentered(n, font: f, color: .white, center: CGPoint(x: r.midX, y: r.midY), maxWidth: w - 16)
        }
    }

    // ───────── 곡 정보 ─────────

    private func drawInfo(_ s: RenderState, _ t: Track, progress: Int, rect: CGRect, artSize: CGFloat, titleSize: CGFloat, artistSize: CGFloat) {
        let th = s.theme
        let artRect = CGRect(x: rect.minX, y: rect.minY, width: artSize, height: artSize)
        let clip = UIBezierPath(roundedRect: artRect, cornerRadius: artSize * 0.11)
        if let img = s.art {
            UIGraphicsGetCurrentContext()?.saveGState()
            clip.addClip()
            img.draw(in: artRect)
            UIGraphicsGetCurrentContext()?.restoreGState()
        } else {
            th.bar.with(alpha: 0.35).setFill()
            clip.fill()
            drawCentered("♪", font: .systemFont(ofSize: artSize * 0.45, weight: .bold), color: th.title.ui,
                         center: CGPoint(x: artRect.midX, y: artRect.midY), maxWidth: artSize)
        }

        let x = artRect.maxX + 26
        let w = rect.maxX - x
        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: artistSize * 0.78, weight: .semibold)
        let barY = rect.minY + artSize - timeFont.lineHeight * 0.55
        let textTop = rect.minY + (artSize - timeFont.lineHeight - titleSize * 1.25 - artistSize * 1.25) / 2

        drawLeft(t.title, font: .systemFont(ofSize: titleSize, weight: .bold), color: th.title.ui,
                 origin: CGPoint(x: x, y: max(rect.minY, textTop)), maxWidth: w)
        drawLeft(t.artist, font: .systemFont(ofSize: artistSize, weight: .medium), color: th.artist.ui,
                 origin: CGPoint(x: x, y: max(rect.minY, textTop) + titleSize * 1.25), maxWidth: w)

        // 재생 바와 시간
        let cur = fmt(progress), total = fmt(t.durationMs)
        let attrs: [NSAttributedString.Key: Any] = [.font: timeFont, .foregroundColor: th.artist.ui]
        let cw = (cur as NSString).size(withAttributes: attrs).width
        let tw = (total as NSString).size(withAttributes: attrs).width
        let ty = barY - timeFont.lineHeight / 2
        (cur as NSString).draw(at: CGPoint(x: x, y: ty), withAttributes: attrs)
        (total as NSString).draw(at: CGPoint(x: rect.maxX - tw, y: ty), withAttributes: attrs)
        let bx = x + cw + 14, bw = max(10, rect.maxX - tw - 14 - bx)
        let bh: CGFloat = 7
        let track = CGRect(x: bx, y: barY - bh / 2, width: bw, height: bh)
        th.artist.with(alpha: 0.28).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: bh / 2).fill()
        let k = t.durationMs > 0 ? CGFloat(progress) / CGFloat(t.durationMs) : 0
        th.bar.ui.setFill()
        UIBezierPath(roundedRect: CGRect(x: bx, y: track.minY, width: max(bh, bw * k), height: bh), cornerRadius: bh / 2).fill()
    }

    // ───────── 가사 세 줄 ─────────

    private func drawLyrics(_ s: RenderState, _ t: Track, progress: Int, rect: CGRect, big: CGFloat, small: CGFloat, spacing: CGFloat) {
        let th = s.theme
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let L = s.lyrics, L.trackId == t.id, L.status == .synced, !L.lines.isEmpty else {
            animating = false
            curIdx = -999
            let msg: String
            switch s.lyrics?.status {
            case .loading?, nil: msg = "가사를 찾고 있습니다."
            case .instrumental?: msg = "♪  연주곡입니다  ♪"
            case .plain?: msg = "이 곡은 시간이 맞춰진 가사가 없습니다."
            case .error?: msg = "가사 서버에 연결하지 못했습니다."
            default: msg = "이 곡의 가사를 찾지 못했습니다."
            }
            drawCentered(msg, font: .systemFont(ofSize: small, weight: .semibold), color: th.other.ui, center: center, maxWidth: rect.width - 20)
            return
        }

        // 맨 앞에 "♪" 줄을 하나 둡니다 (첫 가사 전).
        let texts = ["♪"] + L.lines.map { $0.text.isEmpty ? "♪" : $0.text }
        let ms = progress + s.offsetMs + leadMs
        var lo = 0, hi = L.lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if L.lines[mid].t <= ms { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let idx = ans + 1

        let nowT = CACurrentMediaTime()
        if t.id != trackId { trackId = t.id; curIdx = -999 }
        if idx != curIdx {
            prevIdx = curIdx
            curIdx = idx
            changeAt = (prevIdx == -999 || abs(idx - prevIdx) > 3) ? nowT - animDur : nowT
        }
        let raw = min(1, (nowT - changeAt) / animDur)
        let e = CGFloat(easeOut(raw))
        animating = raw < 1
        let shift = (prevIdx == -999 || abs(curIdx - prevIdx) > 3) ? 0 : CGFloat(curIdx - prevIdx)

        let bigFont = UIFont.systemFont(ofSize: big, weight: .heavy)
        func fitWidth(_ text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
            let w = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)]).width
            return min(w, rect.width - 60)
        }

        // 현재 줄 박스 (이전 줄 폭에서 지금 줄 폭으로 부드럽게)
        let curW = fitWidth(texts[curIdx], size: big, weight: .heavy)
        let prevW = (prevIdx >= 0 && prevIdx < texts.count) ? fitWidth(texts[prevIdx], size: big, weight: .heavy) : curW
        let boxW = (shift == 0 ? curW : prevW + (curW - prevW) * e) + 40
        let boxH = bigFont.lineHeight + 18
        let boxRect = CGRect(x: center.x - boxW / 2, y: center.y - boxH / 2, width: boxW, height: boxH)
        let box = UIBezierPath(roundedRect: boxRect, cornerRadius: 14)
        th.box.ui.setFill()
        box.fill()
        th.box.with(alpha: min(1, th.box.a * 2.4)).setStroke()
        box.lineWidth = 2
        box.stroke()

        for i in max(0, curIdx - 2)...min(texts.count - 1, curIdx + 2) {
            let p = CGFloat(i - curIdx) + shift * (1 - e)
            let ap = abs(p)
            if ap > 1.7 { continue }
            let k = min(1, ap)
            let size = big + (small - big) * k
            var alpha = 1 - 0.35 * k
            if ap > 1 { alpha *= max(0, 1 - (ap - 1) / 0.7) }
            let color = RGBA.lerp(th.current, th.other, k).withAlphaComponent(alpha)
            let weight: UIFont.Weight = k < 0.5 ? .heavy : .semibold
            drawCentered(texts[i], font: .systemFont(ofSize: size, weight: weight), color: color,
                         center: CGPoint(x: center.x, y: center.y + p * spacing), maxWidth: rect.width - (k < 0.5 ? 60 : 30))
        }
    }

    // ───────── 글자 ─────────

    /// 칸보다 길면 글자를 60%까지 줄이고, 그래도 길면 끝을 … 으로 자릅니다.
    private func fitted(_ text: String, font: UIFont, maxWidth: CGFloat) -> (UIFont, CGFloat) {
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        if w <= maxWidth { return (font, w) }
        let scale = max(0.6, maxWidth / w)
        let f = font.withSize(font.pointSize * scale)
        return (f, min(maxWidth, (text as NSString).size(withAttributes: [.font: f]).width))
    }

    private func drawCentered(_ text: String, font: UIFont, color: UIColor, center: CGPoint, maxWidth: CGFloat) {
        let (f, w) = fitted(text, font: font, maxWidth: maxWidth)
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        ps.alignment = .center
        let r = CGRect(x: center.x - w / 2, y: center.y - f.lineHeight / 2, width: w, height: f.lineHeight)
        (text as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: f, .foregroundColor: color, .paragraphStyle: ps], context: nil)
    }

    private func drawLeft(_ text: String, font: UIFont, color: UIColor, origin: CGPoint, maxWidth: CGFloat) {
        let (f, _) = fitted(text, font: font, maxWidth: maxWidth)
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        let r = CGRect(x: origin.x, y: origin.y + (font.lineHeight - f.lineHeight) / 2, width: maxWidth, height: f.lineHeight)
        (text as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: f, .foregroundColor: color, .paragraphStyle: ps], context: nil)
    }

    private func fmt(_ ms: Int) -> String {
        let t = max(0, ms / 1000)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}
