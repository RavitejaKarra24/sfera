import AppKit
import AVFoundation
import AVKit
import Observation
import SwiftUI

/// Shows a movie's picture in its own window while Sfera plays the spatialised sound.
/// The player is muted and slaved to Sfera's audio clock, so the picture follows the
/// sound you hear (including Bluetooth latency), never the other way round.
@MainActor
@Observable
final class VideoOverlayState {
    var showControls = true
    @ObservationIgnored var hideTask: Task<Void, Never>?
}

@MainActor
final class VideoWindowController: NSObject, NSWindowDelegate {
    let player: AVPlayer
    let overlay = VideoOverlayState()
    private(set) var window: NSWindow?
    var onClose: (() -> Void)?
    private var seeking = false

    init(asset: AVURLAsset, title: String) {
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        super.init()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 576),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: VideoScreen(player: player, state: overlay) { [weak window] in
            window?.toggleFullScreen(nil)
        })
        window.center()
        self.window = window

        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return }
            let shown = size.applying(transform)
            let w = abs(shown.width), h = abs(shown.height)
            guard w > 0, h > 0, let window = self?.window else { return }
            window.contentAspectRatio = NSSize(width: w, height: h)
            let width = min(1280, max(640, w))
            window.setContentSize(NSSize(width: width, height: width * h / w))
            window.center()
        }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        onClose = nil
        player.pause()
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        let callback = onClose
        onClose = nil
        window = nil
        callback?()
    }

    private var lastLock = Date.distantPast
    private var locked = false

    /// Pins the picture to the sound. `audibleAt` gives the item time heard at a host time
    /// (nil while there is no steady audio clock, e.g. priming after a seek).
    /// The player's timebase is set to run at rate 1 from that point on the host clock;
    /// it is re-locked only after jumps or if drift exceeds 20 ms.
    func follow(playing: Bool, audibleAt: (UInt64) -> Double?, fallbackTime: Double) {
        guard player.currentItem?.status == .readyToPlay else { return }
        guard playing else {
            locked = false
            if player.rate != 0 { player.pause() }
            if !seeking, abs(player.currentTime().seconds - fallbackTime) > 0.03 {
                seeking = true
                player.seek(to: CMTime(seconds: max(0, fallbackTime), preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in self?.seeking = false }
                }
            }
            return
        }
        let now = HostClock.now
        guard let heardNow = audibleAt(now) else { return }
        let drift = player.currentTime().seconds - heardNow
        let needsLock = !locked || player.rate == 0 || abs(drift) > 0.02
        guard needsLock, Date().timeIntervalSince(lastLock) > 0.4 else { return }
        // Lock slightly in the future so the player can honour it.
        let lead = abs(drift) > 0.5 || !locked ? 0.12 : 0.05
        let host = HostClock.adding(lead, to: now)
        guard let heardThen = audibleAt(host), heardThen >= 0 else { return }
        player.setRate(1, time: CMTime(seconds: heardThen, preferredTimescale: 48000),
                       atHostTime: CMClockMakeHostTimeFromSystemUnits(host))
        locked = true
        lastLock = Date()
    }

    /// Picture time minus heard time, seconds (for the probe).
    func drift(audibleAt: (UInt64) -> Double?) -> Double? {
        guard let heard = audibleAt(HostClock.now) else { return nil }
        return player.currentTime().seconds - heard
    }
}

/// The movie plus a few controls that appear while the pointer moves.
private struct VideoScreen: View {
    let player: AVPlayer
    let state: VideoOverlayState
    let toggleFullScreen: () -> Void
    private var listen: ListenModel { AppEnv.listen }

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerSurface(player: player)
                .ignoresSafeArea()
            if state.showControls {
                controls
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleFullScreen() }
        .onTapGesture { listen.togglePlay() }
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        .onAppear { reveal() }
        .preferredColorScheme(.dark)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { listen.togglePlay() } label: {
                Image(systemName: listen.isPlayingFile ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            Text(Fmt.duration(listen.position)).monospacedDigit()
            Scrubber(fraction: listen.duration > 0 ? listen.position / listen.duration : 0) { listen.seek(fraction: $0) }
            Text(Fmt.duration(listen.duration)).monospacedDigit()
            Text(listen.settings.spatial ? "Spatial" : "Original")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(listen.settings.spatial ? Theme.teal : .white.opacity(0.6))
            Button(action: toggleFullScreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func reveal() {
        let state = state
        if !state.showControls { withAnimation(.easeOut(duration: 0.15)) { state.showControls = true } }
        state.hideTask?.cancel()
        state.hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { state.showControls = false }
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
