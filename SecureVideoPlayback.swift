import SwiftUI
import AVFoundation

/// Local sample-buffer playback; the custom container never becomes a MOV file.
/// At most one pending packet plus a half-second rendering horizon is fed ahead.
@MainActor
final class SecureVideoPlayback: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var ended = false
    @Published private(set) var error: String?
    let display = AVSampleBufferDisplayLayer()
    private let audio = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let source: SecureVideoReader
    private let lease: SessionLease
    private var pending: (SecureVideoFormat.Metadata, Data)?
    private var timer: Timer?
    private var closed = false
    private var eof = false
    private var endTime = 0.0
    private var waitStarted: Date?

    init(reader: MediaReader, lease: SessionLease) throws {
        source = try SecureVideoReader(reader)
        self.lease = lease
        display.videoGravity = .resizeAspect
        synchronizer.addRenderer(display)
        synchronizer.addRenderer(audio)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.setRate(0, time: .zero)
        // No AirPlay routing UI, picture-in-picture controller or external player.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func toggle() {
        guard !closed, !ended, error == nil else { return }
        do {
            try lease.check()
            playing.toggle()
            synchronizer.setRate(playing ? 1 : 0, time: .invalid)
            waitStarted = nil
        } catch { close() }
    }

    private func pump() {
        guard !closed, error == nil, !ended else { return }
        do {
            try lease.check()
            guard !AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .airPlay }) else {
                throw VaultError.unavailable
            }
            guard display.status != .failed, audio.status != .failed else { throw VaultError.unavailable }
            let now = synchronizer.currentTime().seconds
            if eof {
                if now >= endTime {
                    playing = false; ended = true
                    synchronizer.setRate(0, time: .invalid)
                    timer?.invalidate(); timer = nil
                }
                return
            }
            // Work per timer tick is bounded even for a malformed stream.
            for _ in 0..<6 {
                if pending == nil { pending = try source.next() }
                guard let metadata = pending?.0 else {
                    eof = true
                    source.close()
                    return
                }
                if metadata.seconds > now + 0.5 { return }
                let ready = metadata.kind == 1 ? display.isReadyForMoreMediaData : audio.isReadyForMoreMediaData
                guard ready else {
                    if playing {
                        if waitStarted == nil { waitStarted = Date() }
                        if Date().timeIntervalSince(waitStarted!) > 5 { throw VaultError.unavailable }
                    }
                    return
                }
                waitStarted = nil
                let sample = try SecureVideoSamples.make(metadata, payload: pending!.1)
                // Final check immediately before exposing plaintext to renderers.
                try lease.commit {
                    if metadata.kind == 1 { display.enqueue(sample) }
                    else { audio.enqueue(sample) }
                }
                endTime = max(endTime, metadata.seconds + metadata.duration)
                pending?.1.wipe(); pending = nil
            }
        } catch {
            close()
            self.error = "This video could not be authenticated or played."
        }
    }

    func close() {
        guard !closed else { return }
        closed = true; playing = false
        timer?.invalidate(); timer = nil
        synchronizer.setRate(0, time: .invalid)
        display.flushAndRemoveImage()
        audio.flush()
        pending?.1.wipe(); pending = nil
        source.close()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private final class SecurePlaybackSurface: UIView {
    var display: AVSampleBufferDisplayLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        display?.frame = bounds
    }
}

private struct SecurePlaybackVideo: UIViewRepresentable {
    let player: SecureVideoPlayback
    func makeUIView(context: Context) -> SecurePlaybackSurface {
        let view = SecurePlaybackSurface()
        view.display = player.display
        view.layer.addSublayer(player.display)
        return view
    }
    func updateUIView(_ uiView: SecurePlaybackSurface, context: Context) {}
    static func dismantleUIView(_ uiView: SecurePlaybackSurface, coordinator: ()) {
        uiView.display?.removeFromSuperlayer()
        uiView.display = nil
    }
}

struct SecureVideoPlayerView: View {
    @ObservedObject var player: SecureVideoPlayback
    var body: some View {
        ZStack(alignment: .bottom) {
            SecurePlaybackVideo(player: player)
            VStack(spacing: 12) {
                if let error = player.error { Text(error).font(.footnote) }
                if player.ended {
                    Text("End of video · reopen to replay").font(.footnote)
                } else {
                    Button { player.toggle() } label: {
                        Label(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill")
                            .padding().background(.regularMaterial, in: Capsule())
                    }.disabled(player.error != nil)
                }
            }.foregroundStyle(.white).padding(30)
        }
    }
}
