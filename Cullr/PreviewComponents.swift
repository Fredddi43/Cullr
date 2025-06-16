import AVFoundation
import CoreImage
import SwiftUI

// MARK: - Video Thumbnail with Caching and Preview

/// High-performance thumbnail cache with memory management
@MainActor
class ThumbnailCache: ObservableObject {
  static let shared = ThumbnailCache()
  private var cache: [String: Image] = [:]
  private let maxCacheSize = 500  // Limit cache size for memory efficiency
  private var accessOrder: [String] = []  // LRU tracking

  private init() {}

  func get(for key: String) -> Image? {
    if let image = cache[key] {
      // Move to end for LRU
      accessOrder.removeAll { $0 == key }
      accessOrder.append(key)
      return image
    }
    return nil
  }

  func set(_ image: Image, for key: String) {
    // Remove if already exists
    if cache[key] != nil {
      accessOrder.removeAll { $0 == key }
    }

    // Add new entry
    cache[key] = image
    accessOrder.append(key)

    // Enforce cache size limit
    while cache.count > maxCacheSize {
      if let oldestKey = accessOrder.first {
        cache.removeValue(forKey: oldestKey)
        accessOrder.removeFirst()
      }
    }
  }

  func clear() {
    cache.removeAll()
    accessOrder.removeAll()
  }

  var cacheSize: Int { cache.count }
}

/// Video thumbnail view with hover preview functionality
struct VideoThumbnailView: View {
  let url: URL
  let clipTimes: [Double]
  let staticThumbnails: [String: Image]
  let isMuted: Bool
  let playbackType: PlaybackType
  let speedOption: SpeedOption
  @State private var thumbnail: Image?
  @State private var isHovering = false
  @State private var hoverStartTime: Date?

  var body: some View {
    ZStack {
      // Static thumbnail
      if let staticThumb = staticThumbnails[thumbnailKey(url: url, time: 1.0)] {
        staticThumb
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else if let thumb = thumbnail {
        thumb
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
      }

      // Hover preview overlay
      if isHovering {
        HoverPreviewCard(
          url: url,
          times: clipTimes,
          isMuted: isMuted,
          playbackType: playbackType,
          speedOption: speedOption,
          forcePlay: shouldShowPreview
        )
        .opacity(shouldShowPreview ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.3), value: shouldShowPreview)
      }
    }
    .onHover { hovering in
      isHovering = hovering
      if hovering {
        hoverStartTime = Date()
      } else {
        hoverStartTime = nil
      }
    }
    .onAppear {
      loadThumbnail()
    }
  }

  private var shouldShowPreview: Bool {
    guard let startTime = hoverStartTime else { return false }
    return Date().timeIntervalSince(startTime) > 0.8  // 800ms delay
  }

  private func loadThumbnail() {
    let key = thumbnailKey(url: url, time: 1.0)

    if let cached = ThumbnailCache.shared.get(for: key) {
      thumbnail = cached
      return
    }

    Task {
      if let generated = await generateStaticThumbnail(for: url) {
        await MainActor.run {
          thumbnail = generated
          ThumbnailCache.shared.set(generated, for: key)
        }
      }
    }
  }
}

// MARK: - Hover Preview Card

struct HoverPreviewCard: View {
  let url: URL
  let times: [Double]
  let isMuted: Bool
  let playbackType: PlaybackType
  let speedOption: SpeedOption
  let forcePlay: Bool

  @State private var player: AVPlayer?
  @State private var isAssetReady = false
  @State private var currentClip = 0
  @State private var timer: Timer?
  @State private var playbackObserver: NSObjectProtocol?
  @State private var duration: Double = 0
  @State private var startTimes: [Double] = []

  private let startTime: Double = 0.02

  init(
    url: URL, times: [Double], isMuted: Bool, playbackType: PlaybackType, speedOption: SpeedOption,
    forcePlay: Bool
  ) {
    self.url = url
    self.times = times
    self.isMuted = isMuted
    self.forcePlay = forcePlay
    self.playbackType = playbackType
    self.speedOption = speedOption
  }

  var body: some View {
    ZStack {
      Rectangle()
        .fill(Color.gray.opacity(0.3))

      if forcePlay && isAssetReady, let player = player {
        BaseVideoPlayerView(player: player)
          .allowsHitTesting(false)
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
    .onChange(of: forcePlay) { _, shouldPlay in
      if shouldPlay {
        startPlayback()
      } else {
        stopPlayback()
      }
    }
    .onChange(of: speedOption) { _, newValue in
      player?.rate = Float(newValue.rawValue)
    }
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    // Wait for asset to be ready
    Task {
      do {
        let loadedDuration = try await asset.load(.duration)
        await MainActor.run {
          duration = loadedDuration.seconds
          startTimes =
            playbackType == .clips
            ? computeClipStartTimes(duration: duration, count: 5) : [startTime]
          isAssetReady = true
          if forcePlay {
            startPlayback()
          }
        }
      } catch {
        // Handle error silently
      }
    }
  }

  private func startPlayback() {
    guard let player = player else { return }

    if playbackType == .clips && !startTimes.isEmpty {
      playCurrentClip()
    } else {
      player.play()
      player.rate = Float(speedOption.rawValue)
    }
  }

  private func playCurrentClip() {
    guard let player = player, !startTimes.isEmpty else { return }

    let startTime = startTimes[currentClip]
    let cmStartTime = CMTime(seconds: startTime, preferredTimescale: 600)

    player.seek(to: cmStartTime) { [player] _ in
      player.play()
    }
  }

  private func stopPlayback() {
    player?.pause()
    timer?.invalidate()
    timer = nil

    if let observer = playbackObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackObserver = nil
    }
  }

  private func cleanup() {
    stopPlayback()
    player = nil
    isAssetReady = false
  }
}

// MARK: - Folder Hover Preview

struct FolderHoverLoopPreview: View {
  let url: URL
  let isMuted: Bool
  let forcePlay: Bool

  @State private var player: AVPlayer?
  @State private var isAssetReady = false
  @State private var currentClip = 0
  @State private var timer: Timer?
  @State private var opacity: Double = 0
  @State private var duration: Double = 0
  @State private var startTimes: [Double] = []

  private let clipLength: Float = 3.0

  init(url: URL, isMuted: Bool, forcePlay: Bool) {
    self.url = url
    self.isMuted = isMuted
    self.forcePlay = forcePlay
  }

  var body: some View {
    Group {
      if let player = player {
        BaseVideoPlayerView(player: player)
          .opacity(opacity)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .opacity(opacity)
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
    .onChange(of: forcePlay) { _, shouldPlay in
      if shouldPlay && isAssetReady {
        startPlayback()
        withAnimation(.easeIn(duration: 0.3)) {
          opacity = 1.0
        }
      } else {
        stopPlayback()
        withAnimation(.easeOut(duration: 0.2)) {
          opacity = 0.0
        }
      }
    }
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    Task {
      do {
        let loadedDuration = try await asset.load(.duration)
        await MainActor.run {
          duration = loadedDuration.seconds
          startTimes = computeClipStartTimes(duration: duration, count: 5)
          isAssetReady = true
          if forcePlay {
            startPlayback()
            withAnimation(.easeIn(duration: 0.3)) {
              opacity = 1.0
            }
          }
        }
      } catch {
        // Handle error silently
      }
    }
  }

  private func startPlayback() {
    guard let player = player, !startTimes.isEmpty else { return }
    currentClip = 0
    playClip()
  }

  private func playClip() {
    guard let player = player, !startTimes.isEmpty else { return }

    let start = startTimes[currentClip]
    player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { [player] _ in
      player.play()
    }

    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Double(clipLength), repeats: false) { [self] _ in
      currentClip = (currentClip + 1) % startTimes.count
      playClip()
    }
  }

  private func stopPlayback() {
    player?.pause()
    timer?.invalidate()
    timer = nil
  }

  private func cleanup() {
    stopPlayback()
    player = nil
    isAssetReady = false
    opacity = 0
  }
}

// MARK: - Folder Speed Preview

struct FolderSpeedPreview: View {
  let url: URL
  let isMuted: Bool
  let speedOption: SpeedOption
  let forcePlay: Bool

  @State private var player: AVPlayer?
  @State private var isAssetReady = false
  @State private var opacity: Double = 0
  @State private var duration: Double = 0
  @State private var playbackObserver: NSObjectProtocol?

  init(url: URL, isMuted: Bool, speedOption: SpeedOption, forcePlay: Bool) {
    self.url = url
    self.isMuted = isMuted
    self.speedOption = speedOption
    self.forcePlay = forcePlay
  }

  var body: some View {
    Group {
      if let player = player {
        BaseVideoPlayerView(player: player)
          .opacity(opacity)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .opacity(opacity)
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
    .onChange(of: forcePlay) { _, shouldPlay in
      if shouldPlay && isAssetReady {
        startPlayback()
        withAnimation(.easeIn(duration: 0.3)) {
          opacity = 1.0
        }
      } else {
        stopPlayback()
        withAnimation(.easeOut(duration: 0.2)) {
          opacity = 0.0
        }
      }
    }
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    Task {
      do {
        let loadedDuration = try await asset.load(.duration)
        await MainActor.run {
          duration = loadedDuration.seconds
          isAssetReady = true
          if forcePlay {
            startPlayback()
            withAnimation(.easeIn(duration: 0.3)) {
              opacity = 1.0
            }
          }
        }
      } catch {
        // Handle error silently
      }
    }
  }

  private func startPlayback() {
    guard let player = player else { return }

    let startTime = duration * 0.02
    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { [player] _ in
      player.rate = Float(self.speedOption.rawValue)
      player.play()
    }

    playbackObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { [player] _ in
      player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { [player] _ in
        player.rate = Float(self.speedOption.rawValue)
        player.play()
      }
    }
  }

  private func stopPlayback() {
    player?.pause()
    if let observer = playbackObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackObserver = nil
    }
  }

  private func cleanup() {
    stopPlayback()
    player = nil
    isAssetReady = false
    opacity = 0
  }
}

// MARK: - Video Clip Preview

struct VideoClipPreview: View {
  let url: URL
  let clipTimes: [Double]
  let isMuted: Bool

  @State private var player: AVPlayer?
  @State private var currentClip = 0
  @State private var timer: Timer?
  @State private var playbackObserver: NSObjectProtocol?

  private let clipLength: Double = 3.0

  var body: some View {
    Group {
      if let player = player {
        BaseVideoPlayerView(player: player)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    Task {
      do {
        _ = try await asset.load(.duration)
        await MainActor.run {
          startClipPlayback()
        }
      } catch {
        // Handle error silently
      }
    }
  }

  private func startClipPlayback() {
    guard let player = player, !clipTimes.isEmpty else { return }

    currentClip = 0
    playCurrentClip()
  }

  private func playCurrentClip() {
    guard let player = player, !clipTimes.isEmpty else { return }

    let startTime = clipTimes[currentClip]
    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { [player] _ in
      player.play()
    }

    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: clipLength, repeats: false) { [self] _ in
      currentClip = (currentClip + 1) % clipTimes.count
      playCurrentClip()
    }
  }

  private func stopPlayback() {
    player?.pause()
    timer?.invalidate()
    timer = nil
  }

  private func cleanup() {
    stopPlayback()
    player = nil
  }
}

// MARK: - Speed Clip Preview

struct SpeedClipPreview: View {
  let url: URL
  let isMuted: Bool
  let speedOption: SpeedOption

  @State private var player: AVPlayer?
  @State private var duration: Double = 0
  @State private var playbackObserver: NSObjectProtocol?

  var body: some View {
    Group {
      if let player = player {
        BaseVideoPlayerView(player: player)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    Task {
      do {
        let loadedDuration = try await asset.load(.duration)
        await MainActor.run {
          duration = loadedDuration.seconds
          startSpeedPlayback()
        }
      } catch {
        // Handle error silently
      }
    }
  }

  private func startSpeedPlayback() {
    guard let player = player else { return }

    let startTime = duration * 0.02
    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { [player] _ in
      player.rate = Float(self.speedOption.rawValue)
      player.play()
    }

    playbackObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { [player] _ in
      player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { [player] _ in
        player.rate = Float(self.speedOption.rawValue)
        player.play()
      }
    }
  }

  private func stopPlayback() {
    player?.pause()
    if let observer = playbackObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackObserver = nil
    }
  }

  private func cleanup() {
    stopPlayback()
    player = nil
  }
}

// MARK: - Single Clip Preview

/// Simple video clip preview that plays a single clip at a specific time
struct SingleClipPreview: View {
  let url: URL
  let startTime: Double
  let isMuted: Bool

  @State private var player: AVPlayer?
  @State private var playbackObserver: NSObjectProtocol?

  private let clipLength: Double = 3.0

  var body: some View {
    Group {
      if let player = player {
        BaseVideoPlayerView(player: player)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
  }

  private func setupPlayer() {
    // Add a small delay to prevent too many simultaneous player creations
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      let asset = AVURLAsset(url: self.url)
      let playerItem = AVPlayerItem(asset: asset)
      self.player = AVPlayer(playerItem: playerItem)
      self.player?.isMuted = self.isMuted

      Task {
        do {
          _ = try await asset.load(.duration)
          await MainActor.run {
            self.startClipPlayback()
          }
        } catch {
          // Handle error silently
        }
      }
    }
  }

  private func startClipPlayback() {
    guard let player = player else { return }

    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { [player] _ in
      player.play()
    }

    // Set up looping for this specific clip
    playbackObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { [player] _ in
      player.seek(to: CMTime(seconds: self.startTime, preferredTimescale: 600)) { [player] _ in
        player.play()
      }
    }
  }

  private func stopPlayback() {
    player?.pause()
    if let observer = playbackObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackObserver = nil
    }
  }

  private func cleanup() {
    stopPlayback()
    player = nil
  }
}

// MARK: - Utility Functions

/// Generate a static thumbnail for video file
func generateStaticThumbnail(for url: URL) async -> Image? {
  let asset = AVURLAsset(url: url)
  let generator = AVAssetImageGenerator(asset: asset)
  generator.appliesPreferredTrackTransform = true
  generator.maximumSize = CGSize(width: 300, height: 200)

  do {
    let time = CMTime(seconds: 1.0, preferredTimescale: 600)
    let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
    let nsImage = NSImage(
      cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    return Image(nsImage: nsImage)
  } catch {
    return nil
  }
}
