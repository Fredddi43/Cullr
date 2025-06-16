import AVFoundation
import AVKit
import AppKit
import SwiftUI

// MARK: - Base Video Player Components

/// Basic video player view without controls
struct BaseVideoPlayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let playerLayer = AVPlayerLayer(player: player)
    playerLayer.videoGravity = .resizeAspectFill
    playerLayer.frame = .zero
    view.layer = playerLayer
    view.wantsLayer = true
    playerLayer.needsDisplayOnBoundsChange = true
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let playerLayer = nsView.layer as? AVPlayerLayer {
      playerLayer.player = player
      playerLayer.frame = nsView.bounds
    }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    if let playerLayer = nsView.layer as? AVPlayerLayer {
      playerLayer.player = nil
    }
  }
}

/// Video player with playback controls
struct VideoPlayerWithControls: View {
  let player: AVPlayer
  let mode: PlayerMode
  let onPreviousClip: (() -> Void)?
  let onNextClip: (() -> Void)?
  let onSpeedChange: ((SpeedOption) -> Void)?
  let currentSpeed: SpeedOption?
  @Binding var globalIsMuted: Bool

  @State private var isPlaying = false
  @State private var currentTime: Double = 0
  @State private var duration: Double = 0
  @State private var timeObserver: Any?
  @State private var isDragging = false
  @State private var isMuted = false
  @State private var sliderValue: Double = 0
  @State private var wasPlayingBeforeScrub = false

  enum PlayerMode {
    case clips
    case speed
  }

  var body: some View {
    VStack(spacing: 0) {
      // Video player
      BaseVideoPlayerView(player: player)
        .onAppear {
          setupTimeObserver()
          loadDuration()
          updatePlayingState()
          player.isMuted = globalIsMuted
          updateMuteState()
        }
        .onDisappear {
          removeTimeObserver()
        }
        .onTapGesture {
          togglePlayPause()
        }

      // Controls
      VStack(spacing: 12) {
        // Time slider
        HStack {
          Text(timeString(from: currentTime))
            .font(.caption)
            .foregroundColor(.white)
            .frame(width: 50, alignment: .leading)

          Slider(
            value: $sliderValue,
            in: 0...max(duration, 1),
            onEditingChanged: { editing in
              isDragging = editing
              if editing {
                wasPlayingBeforeScrub = isPlaying
                if mode == .clips {
                  player.pause()
                }
              } else {
                seek(to: sliderValue)
                if mode == .clips && wasPlayingBeforeScrub {
                  player.play()
                } else if mode == .speed && isPlaying {
                  player.play()
                }
              }
            }
          )
          .accentColor(.white)
          .onChange(of: sliderValue) { oldValue, newValue in
            if abs(newValue - currentTime) > 0.5 {
              let targetTime = CMTime(seconds: newValue, preferredTimescale: 600)
              player.seek(to: targetTime)
            }
          }

          Text(timeString(from: duration))
            .font(.caption)
            .foregroundColor(.white)
            .frame(width: 50, alignment: .trailing)
        }

        // Main controls row
        HStack(spacing: 20) {
          // Clip navigation (for clips mode)
          if mode == .clips {
            Button(action: { onPreviousClip?() }) {
              Image(systemName: "backward.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(onPreviousClip == nil)
          }

          // Speed controls (for speed mode)
          if mode == .speed, let currentSpeed = currentSpeed {
            Menu {
              ForEach(SpeedOption.allCases, id: \.self) { speed in
                Button(speed.displayName) {
                  onSpeedChange?(speed)
                }
              }
            } label: {
              HStack {
                Text(currentSpeed.displayName)
                Image(systemName: "chevron.up.chevron.down")
              }
              .font(.system(size: 16))
              .foregroundColor(.white)
            }
            .buttonStyle(.plain)
          }

          Spacer()

          // Play/pause button
          Button(action: togglePlayPause) {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
              .font(.system(size: 40))
              .foregroundColor(.white)
          }
          .buttonStyle(.plain)

          Spacer()

          // Mute/unmute button
          Button(action: toggleMute) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.2.fill")
              .font(.system(size: 20))
              .foregroundColor(.white)
          }
          .buttonStyle(.plain)

          // Clip navigation (for clips mode)
          if mode == .clips {
            Button(action: { onNextClip?() }) {
              Image(systemName: "forward.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(onNextClip == nil)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(Color.black.opacity(0.8))
    }
  }

  // MARK: - Private Methods

  private func setupTimeObserver() {
    removeTimeObserver()
    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      let newTime = time.seconds
      if !isDragging && newTime.isFinite {
        currentTime = newTime
        sliderValue = newTime
      }
      updatePlayingState()
    }
  }

  private func removeTimeObserver() {
    if let observer = timeObserver {
      player.removeTimeObserver(observer)
      timeObserver = nil
    }
  }

  private func loadDuration() {
    if let currentItem = player.currentItem {
      let itemDuration = currentItem.duration.seconds
      if itemDuration.isFinite && itemDuration > 0 {
        duration = itemDuration
      }
    }
  }

  private func updatePlayingState() {
    isPlaying = player.rate > 0 && player.error == nil
  }

  private func updateMuteState() {
    isMuted = player.isMuted
    globalIsMuted = player.isMuted
  }

  private func togglePlayPause() {
    if mode == .speed {
      if player.rate > 0 {
        player.pause()
        player.rate = 0
        isPlaying = false
      } else {
        player.play()
        if let speed = currentSpeed {
          player.rate = Float(speed.rawValue)
        } else {
          player.rate = 1.0
        }
        isPlaying = true
      }
    } else {
      if isPlaying {
        player.pause()
      } else {
        player.play()
      }
    }

    updatePlayingState()
  }

  private func toggleMute() {
    globalIsMuted.toggle()
    player.isMuted = globalIsMuted
    isMuted = globalIsMuted
  }

  private func seek(to time: Double) {
    guard time.isFinite && time >= 0 else { return }
    let cmTime = CMTime(seconds: time, preferredTimescale: 600)
    player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
  }
}

// MARK: - Specialized Video Players

/// Single clip looping player with controls
struct ClipLoopingPlayer: View {
  let url: URL
  let numberOfClips: Int
  let clipLength: Int
  @Binding var isMuted: Bool

  @State private var player: AVPlayer?
  @State private var startTimes: [Double] = []
  @State private var currentClip: Int = 0
  @State private var duration: Double = 0
  @State private var boundaryObserver: Any?
  @State private var didAppear: Bool = false
  @State private var showFallback: Bool = false
  @State private var errorMessage: String?

  var body: some View {
    ZStack {
      if showFallback || errorMessage != nil {
        VideoFallbackView(url: url, errorMessage: errorMessage ?? "Unknown error")
      } else if let player = player, !startTimes.isEmpty {
        VideoPlayerWithControls(
          player: player,
          mode: .clips,
          onPreviousClip: previousClip,
          onNextClip: nextClip,
          onSpeedChange: nil,
          currentSpeed: nil,
          globalIsMuted: $isMuted
        )
        .onAppear {
          if !didAppear {
            startLoopingClips()
            didAppear = true
          }
        }
        .onDisappear {
          stopLoopingClips()
          didAppear = false
        }
      } else {
        Color.black
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
  }

  // MARK: - Private Methods

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    Task {
      do {
        let loadedDuration = try await asset.load(.duration)
        await MainActor.run {
          let times = computeClipStartTimes(duration: loadedDuration.seconds, count: numberOfClips)
          duration = loadedDuration.seconds
          startTimes = times
          let item = AVPlayerItem(asset: asset)
          let newPlayer = AVPlayer(playerItem: item)
          newPlayer.isMuted = isMuted
          newPlayer.actionAtItemEnd = .none
          player = newPlayer
        }
      } catch {
        await MainActor.run {
          errorMessage = "Failed to load video"
          showFallback = true
        }
      }
    }
  }

  private func startLoopingClips() {
    guard !startTimes.isEmpty else { return }
    currentClip = 0
    playClip(index: currentClip)
  }

  private func playClip(index: Int) {
    guard let player = player, !startTimes.isEmpty else { return }
    let start = startTimes[index]
    let end = start + Double(clipLength)

    if let observer = boundaryObserver {
      player.removeTimeObserver(observer)
      boundaryObserver = nil
    }

    player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { _ in
      let boundary = CMTime(seconds: end, preferredTimescale: 600)
      self.boundaryObserver = player.addBoundaryTimeObserver(
        forTimes: [NSValue(time: boundary)], queue: .main
      ) {
        self.currentClip = (self.currentClip + 1) % self.startTimes.count
        self.playClip(index: self.currentClip)
      }
      player.play()
    }
  }

  private func previousClip() {
    guard !startTimes.isEmpty, let player = player else { return }
    let currentTime = player.currentTime().seconds
    let closestIndex = findClosestClipIndex(to: currentTime)
    currentClip = closestIndex == 0 ? startTimes.count - 1 : closestIndex - 1
    playClip(index: currentClip)
  }

  private func nextClip() {
    guard !startTimes.isEmpty, let player = player else { return }
    let currentTime = player.currentTime().seconds
    let closestIndex = findClosestClipIndex(to: currentTime)
    currentClip = closestIndex >= startTimes.count - 1 ? 0 : closestIndex + 1
    playClip(index: currentClip)
  }

  private func findClosestClipIndex(to currentTime: Double) -> Int {
    guard !startTimes.isEmpty else { return 0 }
    var closestIndex = 0
    var smallestDistance = abs(startTimes[0] - currentTime)

    for (index, startTime) in startTimes.enumerated() {
      let distance = abs(startTime - currentTime)
      if distance < smallestDistance {
        smallestDistance = distance
        closestIndex = index
      }
    }
    return closestIndex
  }

  private func stopLoopingClips() {
    if let player = player, let observer = boundaryObserver {
      player.removeTimeObserver(observer)
      boundaryObserver = nil
    }
  }

  private func cleanup() {
    stopLoopingClips()
    player?.pause()
    player = nil
    didAppear = false
  }
}

/// Speed-based player with controls
struct SpeedPlayer: View {
  let url: URL
  @Binding var speedOption: SpeedOption
  @Binding var isMuted: Bool

  @State private var player: AVPlayer?
  @State private var duration: Double = 0
  @State private var didAppear: Bool = false
  @State private var showFallback: Bool = false
  @State private var errorMessage: String?
  @State private var playbackEndObserver: NSObjectProtocol?

  var body: some View {
    ZStack {
      if showFallback || errorMessage != nil {
        VideoFallbackView(url: url, errorMessage: errorMessage ?? "Unknown error")
      } else if let player = player {
        VideoPlayerWithControls(
          player: player,
          mode: .speed,
          onPreviousClip: nil,
          onNextClip: nil,
          onSpeedChange: { newSpeed in
            speedOption = newSpeed
            updatePlaybackSpeed()
          },
          currentSpeed: speedOption,
          globalIsMuted: $isMuted
        )
        .onAppear {
          if !didAppear {
            startSpeedPlayback()
            didAppear = true
          }
        }
        .onDisappear {
          stopPlayback()
          didAppear = false
        }
      } else {
        Color.black
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
    .onChange(of: speedOption) { oldValue, newValue in
      updatePlaybackSpeed()
    }
  }

  // MARK: - Private Methods

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    Task {
      do {
        let loadedDuration = try await asset.load(.duration)
        await MainActor.run {
          duration = loadedDuration.seconds
          let item = AVPlayerItem(asset: asset)
          let newPlayer = AVPlayer(playerItem: item)
          newPlayer.isMuted = isMuted
          player = newPlayer
          startSpeedPlayback()
        }
      } catch {
        await MainActor.run {
          errorMessage = "Failed to load video"
          showFallback = true
        }
      }
    }
  }

  private func startSpeedPlayback() {
    guard let player = player else { return }
    let startTime = duration * 0.02

    player.rate = Float(speedOption.rawValue)
    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { _ in
      player.rate = Float(self.speedOption.rawValue)
      player.play()
    }

    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { _ in
        player.rate = Float(self.speedOption.rawValue)
        player.play()
      }
    }
  }

  private func updatePlaybackSpeed() {
    guard let player = player else { return }
    player.rate = Float(speedOption.rawValue)
  }

  private func stopPlayback() {
    player?.pause()
    player?.rate = 0
    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }
  }

  private func cleanup() {
    stopPlayback()
    player = nil
    didAppear = false
  }
}

// MARK: - Fallback View

/// Displayed when video playback fails
struct VideoFallbackView: View {
  let url: URL
  let errorMessage: String

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "play.circle.fill")
        .font(.system(size: 64))
        .foregroundColor(.white)
      Text("Video Unavailable")
        .font(.headline)
        .foregroundColor(.white)
      Text(url.lastPathComponent)
        .font(.subheadline)
        .foregroundColor(.secondary)
      Text(errorMessage)
        .font(.caption)
        .foregroundColor(.red)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}
