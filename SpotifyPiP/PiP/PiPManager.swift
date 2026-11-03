import AVKit
import AVFoundation
import CoreMedia
import UIKit

/// PiP 창에 보여 줄 화면을 담는 뷰 (영상 대신 직접 그린 그림을 넣습니다)
final class PiPDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 그린 그림을 영상 프레임으로 만들어 PiP 창에 계속 넣어 줍니다.
@MainActor
final class PiPManager: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var possible = false
    @Published private(set) var supported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var lastError: String? = nil

    let view = PiPDisplayView()
    private var controller: AVPictureInPictureController?
    private var possibleObs: NSKeyValueObservation?
    private let renderer = CardRenderer()
    private var timer: Timer?
    private var lastFrame: CFTimeInterval = 0
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var silent: AVAudioPlayer?

    /// 그릴 내용을 알려 주는 함수
    var state: () -> RenderState? = { nil }
    /// PiP 창의 재생/일시정지 버튼
    var onSetPlaying: (Bool) -> Void = { _ in }
    /// 재생 버튼 모양을 정하는 값 (PiP 쪽에서 다른 스레드로 물어볼 수 있어서 따로 둡니다)
    nonisolated(unsafe) var pausedForPiP = false

    func setup(autoStart: Bool) {
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        configureAudio()
        startRendering()
        guard supported, controller == nil else { return }
        let src = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: src)
        c.delegate = self
        c.requiresLinearPlayback = true
        c.canStartPictureInPictureAutomaticallyFromInline = autoStart
        possibleObs = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let v = c.isPictureInPicturePossible
            Task { @MainActor in self?.possible = v }
        }
        controller = c
    }

    func setAutoStart(_ on: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = on
    }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive {
            c.stopPictureInPicture()
        } else {
            configureAudio()
            c.startPictureInPicture()
        }
    }

    /// 재생 상태가 바뀌면 PiP 창의 버튼 모양도 바꿉니다.
    func playbackChanged(paused: Bool) {
        if pausedForPiP != paused {
            pausedForPiP = paused
            controller?.invalidatePlaybackState()
        }
    }

    // ───────── 오디오 (백그라운드에서도 계속 그리기 위해) ─────────

    private func configureAudio() {
        // 다른 앱(Spotify) 소리를 끊지 않도록 섞어서 재생하는 모드를 씁니다.
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
    }

    /// 소리 없는 오디오를 틀어 두면, 앱이 뒤로 가도 iOS 가 멈추지 않습니다.
    private func startSilent() {
        if silent == nil {
            silent = try? AVAudioPlayer(data: Self.silentWav())
            silent?.numberOfLoops = -1
            silent?.volume = 0
        }
        silent?.play()
    }

    private func stopSilent() { silent?.stop() }

    private static func silentWav() -> Data {
        let rate: UInt32 = 8000, seconds: UInt32 = 1
        let dataSize = rate * seconds * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }

    // ───────── 그리기 ─────────

    private func startRendering() {
        timer?.invalidate()
        // 1초에 20번 확인하고, 애니메이션 중이 아니면 1초에 5번만 그립니다.
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.frame() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func frame() {
        guard let s = state() else { return }
        let now = CACurrentMediaTime()
        if !renderer.animating && now - lastFrame < 0.2 { return }
        lastFrame = now
        let size = s.layout.size
        guard let pb = makeBuffer(size) else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            renderer.draw(s, size: size)
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        enqueue(pb)
    }

    private func makeBuffer(_ size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return pb
    }

    private func enqueue(_ pb: CVPixelBuffer) {
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 20),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let layer = view.displayLayer
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
    }

    fileprivate func didChange(active a: Bool, error: String? = nil) {
        active = a
        if let error { lastError = error }
        if a { startSilent(); lastError = nil } else { stopSilent() }
    }
}

// ───────── PiP 쪽에서 부르는 함수들 ─────────

extension PiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.didChange(active: true) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.didChange(active: false) }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.didChange(active: false, error: "PiP 창을 띄우지 못했습니다. (\(msg))") }
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        pausedForPiP = !playing
        Task { @MainActor in
            self.onSetPlaying(playing)
            self.controller?.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        // 끝이 없는 생방송처럼 보이게 해서 되감기 막대를 숨깁니다.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        pausedForPiP
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
