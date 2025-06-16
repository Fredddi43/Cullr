import AVFoundation
import CoreImage
import SwiftUI

// MARK: - Thumbnail Cache

/// Global thumbnail cache for performance optimization
class ThumbnailCache: ObservableObject {
  static let shared = ThumbnailCache()
  private var cache: [URL: Image] = [:]

  init() {}

  func get(_ url: URL) -> Image? {
    return cache[url]
  }

  func set(_ url: URL, image: Image) {
    cache[url] = image
  }
}

// MARK: - Video Thumbnail Components

/// Basic video thumbnail view with caching
struct VideoThumbnailView: View {
  let url: URL
  @State private var thumbnail: Image?
  @State private var isLoading = true

  var body: some View {
    ZStack {
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else if isLoading {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle())
      } else {
        Color.black
      }
    }
    .task {
      await loadThumbnail()
    }
  }

  private func loadThumbnail() async {
    if let cached = ThumbnailCache.shared.get(url) {
      thumbnail = cached
      isLoading = false
      return
    }

    do {
      let asset = AVURLAsset(url: url)
      let duration = asset.duration.seconds
      let time = max(duration * 0.02, 0.1)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 600, height: 338)
      generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
      generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
      let cmTime = CMTime(seconds: time, preferredTimescale: 600)
      let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
      let image = Image(decorative: cgImage, scale: 1.0)

      await MainActor.run {
        ThumbnailCache.shared.set(url, image: image)
        thumbnail = image
        isLoading = false
      }
    } catch {
      await MainActor.run {
        isLoading = false
      }
    }
  }
}

// MARK: - Interactive Preview Components

/// Preview card that plays video on hover
struct HoverPreviewCard: View {
  let url: URL
  let thumbnail: Image?
  let isMuted: Bool
  var startTime: Double = 0
  var forcePlay: Bool = false
  var playbackType: PlaybackType
  var speedOption: SpeedOption

  @State private var player: AVPlayer?
  @State private var asset: AVURLAsset?
  @State private var duration: Double = 0
  @State private var playbackEndObserver: NSObjectProtocol?
  @State private var isAssetReady: Bool = false

  var body: some View {
    ZStack {
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Color.black
      }

      if forcePlay && playbackType == .speed, let player = player {
        BaseVideoPlayerView(player: player)
          .onAppear {
            if isAssetReady {
              startSpeedPlayback()
            }
          }
          .onDisappear {
            stopPlayback()
          }
      } else if forcePlay && playbackType == .clips, let player = player {
        BaseVideoPlayerView(player: player)
          .onAppear {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            player.play()
          }
          .onDisappear {
            stopPlayback()
          }
      }
    }
    .clipped()
    .onAppear {
      if asset == nil {
        preCreateAsset()
      }
    }
    .onChange(of: speedOption) { _ in
      if forcePlay && playbackType == .speed && isAssetReady {
        updateSpeedPlayback()
      }
    }
    .onChange(of: forcePlay) { newForcePlay in
      if newForcePlay && playbackType == .speed {
        if isAssetReady {
          createPlayerForSpeed()
        }
      } else if newForcePlay && playbackType == .clips {
        createPlayerForClips()
      } else if !newForcePlay {
        stopPlayback()
      }
    }
  }

  // MARK: - Private Methods

  private func preCreateAsset() {
    asset = AVURLAsset(url: url)

    if playbackType == .speed {
      Task {
        if let asset = asset {
          let loadedDuration = try? await asset.load(.duration)
          await MainActor.run {
            self.duration = loadedDuration?.seconds ?? 0
            self.isAssetReady = true
          }
        }
      }
    } else {
      isAssetReady = true
    }
  }

  private func createPlayerForClips() {
    guard let asset = asset else {
      preCreateAsset()
      return
    }
    let item = AVPlayerItem(asset: asset)
    let newPlayer = AVPlayer(playerItem: item)
    newPlayer.isMuted = isMuted
    player = newPlayer
  }

  private func createPlayerForSpeed() {
    guard let asset = asset, isAssetReady else { return }
    let playerItem = AVPlayerItem(asset: asset)
    let newPlayer = AVPlayer(playerItem: playerItem)
    newPlayer.isMuted = isMuted
    player = newPlayer
    startSpeedPlayback()
  }

  private func startSpeedPlayback() {
    guard let player = player, duration > 0 else { return }

    let startTime = duration * 0.02
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

  private func updateSpeedPlayback() {
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

    player = nil
  }
}

// MARK: - Specialized Preview Components

/// Folder view hover loop preview
struct FolderHoverLoopPreview: View {
  let url: URL
  let isMuted: Bool
  let numberOfClips: Int
  let clipLength: Int
  let playbackType: PlaybackType
  let speedOption: SpeedOption

  @State private var isHovered = false
  @State private var player: AVPlayer?
  @State private var asset: AVURLAsset?
  @State private var currentClip: Int = 0
  @State private var timer: Timer?
  @State private var startTimes: [Double] = []
  @State private var duration: Double = 0
  @State private var fadeOpacity: Double = 0.0
  @State private var thumbnail: Image?
  @State private var playbackEndObserver: NSObjectProtocol?
  @State private var isAssetReady: Bool = false

  var body: some View {
    ZStack {
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Color.black
      }

      if isHovered, let player = player {
        BaseVideoPlayerView(player: player)
          .opacity(fadeOpacity)
          .onAppear {
            withAnimation(.easeIn(duration: 0.2)) {
              fadeOpacity = 1.0
            }
            if playbackType == .clips {
              startLoopingClips()
            } else {
              startSpeedPlayback()
            }
          }
          .onDisappear {
            withAnimation(.easeOut(duration: 0.2)) {
              fadeOpacity = 0.0
            }
            stopPlayback()
          }
      }
    }
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        if player == nil && isAssetReady {
          createPlayer()
        }
      } else {
        stopPlayback()
      }
    }
    .onAppear {
      if asset == nil {
        preCreateAsset()
      }
    }
    .task {
      await loadThumbnail()
    }
    .clipped()
  }

  // MARK: - Private Methods

  private func loadThumbnail() async {
    if let cached = ThumbnailCache.shared.get(url) {
      thumbnail = cached
    } else {
      do {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 675)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cmTime = CMTime(seconds: asset.duration.seconds * 0.02, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
        let image = Image(decorative: cgImage, scale: 1.0)
        ThumbnailCache.shared.set(url, image: image)
        thumbnail = image
      } catch {
        // Handle error silently
      }
    }
  }

  private func preCreateAsset() {
    asset = AVURLAsset(url: url)

    Task {
      if let asset = asset {
        let loadedDuration = try? await asset.load(.duration)
        await MainActor.run {
          self.duration = loadedDuration?.seconds ?? 0
          if playbackType == .clips && duration > 0 {
            startTimes = computeClipStartTimes(duration: duration, count: numberOfClips)
          }
          self.isAssetReady = true

          if isHovered && player == nil {
            createPlayer()
          }
        }
      }
    }
  }

  private func createPlayer() {
    guard let asset = asset, isAssetReady else { return }

    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    if playbackType == .clips {
      startLoopingClips()
    } else {
      startSpeedPlayback()
    }
  }

  private func startSpeedPlayback() {
    guard let player = player else { return }

    player.rate = Float(speedOption.rawValue)
    player.seek(to: CMTime(seconds: duration * 0.02, preferredTimescale: 600))
    player.play()

    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      player.seek(to: CMTime(seconds: self.duration * 0.02, preferredTimescale: 600))
      player.play()
    }
  }

  private func startLoopingClips() {
    guard let player = player else { return }

    currentClip = 0
    playCurrentClip()
  }

  private func playCurrentClip() {
    guard let player = player, !startTimes.isEmpty else { return }

    let startTime = startTimes[currentClip]
    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
    player.rate = 1.0
    player.play()

    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Double(clipLength), repeats: false) { _ in
      self.currentClip = (self.currentClip + 1) % self.startTimes.count
      self.playCurrentClip()
    }
  }

  private func stopPlayback() {
    player?.pause()
    player?.rate = 0
    timer?.invalidate()
    timer = nil

    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }
  }
}

/// Speed-focused folder preview
struct FolderSpeedPreview: View {
  let url: URL
  let isMuted: Bool
  let speedOption: SpeedOption

  @State private var isHovered = false
  @State private var player: AVPlayer?
  @State private var asset: AVURLAsset?
  @State private var duration: Double = 0
  @State private var fadeOpacity: Double = 0.0
  @State private var thumbnail: Image?
  @State private var playbackEndObserver: NSObjectProtocol?
  @State private var isAssetReady: Bool = false

  var body: some View {
    ZStack {
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Color.black
      }

      if isHovered, let player = player {
        BaseVideoPlayerView(player: player)
          .opacity(fadeOpacity)
          .onAppear {
            withAnimation(.easeIn(duration: 0.2)) { fadeOpacity = 1.0 }
            startSpeedPlayback()
          }
          .onDisappear {
            withAnimation(.easeOut(duration: 0.2)) { fadeOpacity = 0.0 }
            stopPlayback()
          }
      }
    }
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        if player == nil && isAssetReady {
          createPlayer()
        }
      } else {
        stopPlayback()
      }
    }
    .onAppear {
      if asset == nil {
        preCreateAsset()
      }
    }
    .onChange(of: speedOption) { _ in
      if isHovered, let player = player {
        updateSpeedPlayback()
      }
    }
    .task {
      await loadThumbnail()
    }
    .clipped()
  }

  // MARK: - Private Methods

  private func loadThumbnail() async {
    if let cached = ThumbnailCache.shared.get(url) {
      thumbnail = cached
    } else {
      do {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 338)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let time = max(asset.duration.seconds * 0.02, 0.1)
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
        let image = Image(decorative: cgImage, scale: 1.0)
        ThumbnailCache.shared.set(url, image: image)
        thumbnail = image
      } catch {
        // Handle error silently
      }
    }
  }

  private func preCreateAsset() {
    asset = AVURLAsset(url: url)

    Task {
      if let asset = asset {
        let loadedDuration = try? await asset.load(.duration)
        await MainActor.run {
          self.duration = loadedDuration?.seconds ?? 0
          self.isAssetReady = true

          if isHovered && player == nil {
            createPlayer()
          }
        }
      }
    }
  }

  private func createPlayer() {
    guard let asset = asset, isAssetReady else { return }

    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted
    startSpeedPlayback()
  }

  private func startSpeedPlayback() {
    guard let player = player, duration > 0 else { return }

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

  private func updateSpeedPlayback() {
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
}

// MARK: - Simple Video Clip Preview

/// Simple video clip preview for side-by-side view
struct VideoClipPreview: View {
  let url: URL
  let startTime: Double
  let length: Double
  let isMuted: Bool

  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let player = player {
        BaseVideoPlayerView(player: player)
          .onAppear {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            player.play()
          }
          .onDisappear {
            player.pause()
          }
      } else {
        Color.black
          .onAppear {
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = isMuted
            player = newPlayer
          }
      }
    }
  }
}

/// Speed clip preview for side-by-side view
struct SpeedClipPreview: View {
  let url: URL
  let speedOption: SpeedOption
  let isMuted: Bool

  @State private var player: AVPlayer?
  @State private var duration: Double = 0
  @State private var playbackEndObserver: NSObjectProtocol?

  var body: some View {
    Group {
      if let player = player {
        BaseVideoPlayerView(player: player)
          .onAppear {
            startSpeedPlayback()
          }
          .onDisappear {
            stopPlayback()
          }
      } else {
        Color.black
          .onAppear {
            setupPlayer()
          }
      }
    }
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    asset.loadValuesAsynchronously(forKeys: ["duration"]) {
      let d = asset.duration.seconds
      DispatchQueue.main.async {
        duration = d
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isMuted
        player = newPlayer
        startSpeedPlayback()
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

  private func stopPlayback() {
    player?.pause()
    player?.rate = 0
    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }
  }
}

// MARK: - Utility Functions

/// Generates static thumbnail for batch list views
/// - Parameters:
///   - url: Video file URL
///   - time: Time offset for thumbnail
///   - completion: Completion handler with generated image
func generateStaticThumbnail(for url: URL, at time: Double, completion: @escaping (Image?) -> Void)
{
  DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.01) {
    let asset = AVAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 600, height: 338)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

    let actualTime = max(time, 0.1)
    let cmTime = CMTime(seconds: actualTime, preferredTimescale: 600)

    if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
      let image = Image(decorative: cgImage, scale: 1.0)
      DispatchQueue.main.async {
        completion(image)
      }
    } else {
      DispatchQueue.main.async {
        completion(nil)
      }
    }
  }
}
