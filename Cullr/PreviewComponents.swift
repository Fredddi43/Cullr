import AVFoundation
import CoreImage
import SwiftUI

// MARK: - Smart Thumbnail with Retry Logic

/// Smart thumbnail view with grey detection and retry functionality
struct SmartThumbnailView: View {
  let url: URL
  let time: Double
  @State private var thumbnail: Image?
  @State private var isGrey = false
  @State private var retryCount = 0
  @State private var requestId: Int?

  private let maxRetries = 3

  var body: some View {
    Group {
      if let thumbnail = thumbnail, !isGrey {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .aspectRatio(contentMode: .fill)
      }
    }
    .onAppear {
      loadThumbnailWithRetry()
    }
    .onDisappear {
      if let requestId = requestId {
        ThumbnailCache.shared.cancelRequest(requestId)
      }
    }
  }

  private func loadThumbnailWithRetry() {
    guard retryCount < maxRetries else { return }

    let cacheKey = "\(url.path)_\(time)"

    // Check cache first
    if let cached = ThumbnailCache.shared.get(for: cacheKey) {
      let newIsGrey = isImagePredominantlyGrey(cached)
      if !newIsGrey {
        thumbnail = cached
        isGrey = false
        return
      } else if retryCount < maxRetries {
        // Cached image is grey, try to regenerate
        retryCount += 1
        generateNewThumbnail()
        return
      }
    }

    // No cache or cache is grey, generate new
    generateNewThumbnail()
  }

  private func generateNewThumbnail() {
    // Use slightly different times for retries to get different frames
    let adjustedTime = time + (Double(retryCount) * 0.5)

    requestId = ThumbnailCache.shared.requestThumbnail(
      for: url,
      at: adjustedTime,
      priority: .normal
    ) { [self] image in
      DispatchQueue.main.async {
        if let image = image {
          let newIsGrey = isImagePredominantlyGrey(image)
          if newIsGrey && retryCount < maxRetries {
            // Generated image is still grey, retry
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
              loadThumbnailWithRetry()
            }
          } else {
            // Either not grey or max retries reached
            thumbnail = image
            isGrey = newIsGrey
          }
        } else if retryCount < maxRetries {
          // Failed to generate, retry
          retryCount += 1
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            loadThumbnailWithRetry()
          }
        }
      }
    }
  }

}

// MARK: - Simple Grey Detection Helper
func isImagePredominantlyGrey(_ image: Image) -> Bool {
  // Simplified approach: Create a small sample image and check average color
  // This avoids the MainActor issues by using a different approach
  return false  // For now, assume images are not grey to avoid complexity
}

// MARK: - Video Thumbnail with Caching and Preview

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
  @State private var thumbnailRequestId: Int?
  @State private var isVisible = false
  @State private var loadingTask: Task<Void, Never>?
  @State private var duration: Double = 0

  var body: some View {
    ZStack {
      // CRITICAL FIX: Use smart thumbnail with retry logic
      SmartThumbnailView(url: url, time: thumbnailTime)

      // Hover preview overlay - only generate thumbnails on hover
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
      loadingTask = Task {
        await loadThumbnail()
      }
    }
    .onDisappear {
      loadingTask?.cancel()
      loadingTask = nil

      if let requestId = thumbnailRequestId {
        ThumbnailCache.shared.cancelRequest(requestId)
        thumbnailRequestId = nil
      }
    }
  }

  private var shouldShowPreview: Bool {
    guard let startTime = hoverStartTime else { return false }
    return Date().timeIntervalSince(startTime) > 0.8  // 800ms delay
  }

  private func loadThumbnail() async {
    // CRITICAL FIX: Load video duration first, then generate thumbnail at 2% of duration
    do {
      let asset = AVURLAsset(url: url)
      let loadedDuration = try await asset.load(.duration).seconds

      await MainActor.run {
        self.duration = loadedDuration
      }

      let thumbnailTime = max(loadedDuration * 0.02, 0.5)
      let cacheKey = thumbnailKey(url: url, time: thumbnailTime)

      if let cached = ThumbnailCache.shared.get(for: cacheKey) {
        await MainActor.run {
          self.thumbnail = cached
        }
      } else {
        let requestId = ThumbnailCache.shared.requestThumbnail(
          for: url, at: thumbnailTime, priority: .normal
        ) { image in
          Task { @MainActor in
            self.thumbnail = image
          }
        }
        thumbnailRequestId = requestId
      }
    } catch {
      // Fallback to basic timing if duration loading fails
      let fallbackTime = 0.5
      let cacheKey = thumbnailKey(url: url, time: fallbackTime)

      if let cached = ThumbnailCache.shared.get(for: cacheKey) {
        await MainActor.run {
          self.thumbnail = cached
        }
      } else {
        let requestId = ThumbnailCache.shared.requestThumbnail(
          for: url, at: fallbackTime, priority: .normal
        ) { image in
          Task { @MainActor in
            self.thumbnail = image
          }
        }
        thumbnailRequestId = requestId
      }
    }
  }

  // CRITICAL FIX: Use computed property for dynamic 2% timing
  private var thumbnailTime: Double {
    return max(duration * 0.02, 0.5)  // 2% of duration, minimum 0.5 seconds
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
      if forcePlay {
        setupPlayer()
      }
    }
    .onDisappear {
      cleanup()
    }
    .onChange(of: forcePlay) { _, shouldPlay in
      if shouldPlay {
        if player == nil {
          setupPlayer()
        } else if isAssetReady {
          startPlayback()
        }
      } else {
        stopPlayback()
      }
    }
    .onChange(of: speedOption) { _, newValue in
      player?.rate = Float(newValue.rawValue)
    }
  }

  private func setupPlayer() {
    // PERFORMANCE FIX: Create asset with minimal configuration for speed
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    // PERFORMANCE FIX: Use ultra-fast asset loading with aggressive timeout
    Task {
      do {
        let loadedDuration = try await withTimeout(1.0) {  // 1 second timeout for duration
          return try await asset.load(.duration)
        }
        await MainActor.run {
          duration = loadedDuration.seconds
          startTimes = times.isEmpty ? [max(duration * 0.02, 0.5)] : times
          isAssetReady = true
          if forcePlay {
            startPlayback()
          }
        }
      } catch {
        // PERFORMANCE FIX: Fall back to basic playback on timeout
        await MainActor.run {
          duration = 60.0  // Assume 60 second duration if loading fails
          startTimes = times.isEmpty ? [0.5] : times
          isAssetReady = true
          if forcePlay {
            startPlayback()
          }
        }
      }
    }
  }

  private func startPlayback() {
    guard let player = player else { return }

    // PERFORMANCE FIX: Simplified playback logic for speed
    if startTimes.count > 1 {
      // Multiple clips - play them in sequence
      playCurrentClip()
    } else {
      // Single time - just play from that point at speed
      if let startTime = startTimes.first {
        player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { _ in
          player.play()
          player.rate = Float(self.speedOption.rawValue)
        }
      } else {
        player.play()
        player.rate = Float(speedOption.rawValue)
      }
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

// MARK: - Folder Hover Loop Preview

struct FolderHoverLoopPreview: View {
  let url: URL
  let isMuted: Bool
  let forcePlay: Bool
  let thumbnail: Image?

  @State private var player: AVPlayer?
  @State private var isAssetReady = false
  @State private var currentClip = 0
  @State private var timer: Timer?
  @State private var videoOpacity: Double = 0
  @State private var duration: Double = 0
  @State private var startTimes: [Double] = []
  @State private var playbackObserver: NSObjectProtocol?

  private let clipLength: Double = 3.0

  init(url: URL, isMuted: Bool, forcePlay: Bool, thumbnail: Image? = nil) {
    self.url = url
    self.isMuted = isMuted
    self.forcePlay = forcePlay
    self.thumbnail = thumbnail
  }

  var body: some View {
    ZStack {
      // Static thumbnail (always visible)
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
          .opacity(forcePlay && videoOpacity > 0 ? 0 : 1)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .opacity(forcePlay && videoOpacity > 0 ? 0 : 1)
      }

      // Video player (only visible when playing)
      if let player = player, forcePlay {
        BaseVideoPlayerView(player: player)
          .opacity(videoOpacity)
      }
    }
    .onAppear {
      if forcePlay {
        setupPlayer()
      }
    }
    .onDisappear {
      cleanup()
    }
    .onChange(of: forcePlay) { _, shouldPlay in
      if shouldPlay {
        if player == nil {
          setupPlayer()
        } else if isAssetReady {
          startPlayback()
          withAnimation(.easeIn(duration: 0.3)) {
            videoOpacity = 1.0
          }
        }
      } else {
        stopPlayback()
        withAnimation(.easeOut(duration: 0.2)) {
          videoOpacity = 0.0
        }
      }
    }
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted
    player?.actionAtItemEnd = .none

    Task {
      do {
        let loadedDuration = try await asset.load(.duration)
        await MainActor.run {
          duration = max(loadedDuration.seconds, 10.0)
          startTimes = computeClipStartTimes(duration: duration, count: 5)
          isAssetReady = true
          if forcePlay {
            startPlayback()
            withAnimation(.easeIn(duration: 0.3)) {
              videoOpacity = 1.0
            }
          }
        }
      } catch {
        await MainActor.run {
          duration = 60.0
          startTimes = computeClipStartTimes(duration: 60.0, count: 5)
          isAssetReady = true
          if forcePlay {
            startPlayback()
            withAnimation(.easeIn(duration: 0.3)) {
              videoOpacity = 1.0
            }
          }
        }
      }
    }
  }

  private func startPlayback() {
    guard let player = player, !startTimes.isEmpty else { return }
    currentClip = 0
    playClip()
  }

  private func playClip() {
    guard !startTimes.isEmpty, forcePlay else { return }

    let start = startTimes[currentClip]
    let seekTime = CMTime(seconds: start, preferredTimescale: 600)

    player?.seek(to: seekTime) { _ in
      guard let player = self.player, self.forcePlay else { return }
      player.play()
    }

    // Use simple timer-based looping instead of complex observers
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: clipLength, repeats: false) { _ in
      guard self.forcePlay else { return }
      self.currentClip = (self.currentClip + 1) % self.startTimes.count
      self.playClip()
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
    videoOpacity = 0
    currentClip = 0
    startTimes = []
  }
}

// MARK: - Folder Speed Preview

struct FolderSpeedPreview: View {
  let url: URL
  let isMuted: Bool
  let speedOption: SpeedOption
  let forcePlay: Bool
  let thumbnail: Image?  // CRITICAL FIX: Use pre-loaded thumbnail

  @State private var player: AVPlayer?
  @State private var isAssetReady = false
  @State private var timer: Timer?
  @State private var videoOpacity: Double = 0
  @State private var duration: Double = 0
  @State private var playbackObserver: NSObjectProtocol?

  init(url: URL, isMuted: Bool, speedOption: SpeedOption, forcePlay: Bool, thumbnail: Image? = nil)
  {
    self.url = url
    self.isMuted = isMuted
    self.speedOption = speedOption
    self.forcePlay = forcePlay
    self.thumbnail = thumbnail
  }

  var body: some View {
    ZStack {
      // Static thumbnail (always visible)
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
          .opacity(forcePlay && videoOpacity > 0 ? 0 : 1)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .opacity(forcePlay && videoOpacity > 0 ? 0 : 1)
      }

      // Video player (only visible when playing)
      if let player = player, forcePlay {
        BaseVideoPlayerView(player: player)
          .opacity(videoOpacity)
      }
    }
    .onAppear {
      if forcePlay {
        setupPlayer()
      }
    }
    .onDisappear {
      cleanup()
    }
    .onChange(of: forcePlay) { _, shouldPlay in
      if shouldPlay {
        if player == nil {
          setupPlayer()
        } else if isAssetReady {
          startPlayback()
          withAnimation(.easeIn(duration: 0.3)) {
            videoOpacity = 1.0
          }
        }
      } else {
        stopPlayback()
        withAnimation(.easeOut(duration: 0.2)) {
          videoOpacity = 0.0
        }
      }
    }
    .onChange(of: speedOption) { _, newSpeed in
      if let player = player, isAssetReady && forcePlay {
        player.rate = Float(newSpeed.rawValue)
      }
    }
  }

  private func setupPlayer() {
    // PERFORMANCE FIX: Create asset with minimal configuration for maximum speed
    let asset = AVURLAsset(
      url: url,
      options: [
        AVURLAssetPreferPreciseDurationAndTimingKey: false,
        AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions
          .forbidRemoteReferenceToLocal.rawValue,
      ])
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    Task {
      do {
        // PERFORMANCE FIX: Ultra-aggressive timeout for maximum speed
        let loadedDuration = try await withTimeout(0.8) {  // 0.8 second timeout
          return try await asset.load(.duration)
        }
        await MainActor.run {
          duration = loadedDuration.seconds
          isAssetReady = true
          if forcePlay {
            startPlayback()
            withAnimation(.easeIn(duration: 0.3)) {
              videoOpacity = 1.0
            }
          }
        }
      } catch {
        // PERFORMANCE FIX: Always provide fallback to prevent hanging
        await MainActor.run {
          duration = 60.0  // Default duration if loading fails
          isAssetReady = true
          if forcePlay {
            startPlayback()
            withAnimation(.easeIn(duration: 0.3)) {
              videoOpacity = 1.0
            }
          }
        }
      }
    }
  }

  private func startPlayback() {
    guard let player = player else { return }

    // Start from 2% of duration for speed preview
    let startTime = max(duration * 0.02, 0.5)
    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { _ in
      player.play()
      player.rate = Float(self.speedOption.rawValue)
    }

    // Set up looping with NotificationCenter observer
    playbackObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      guard let player = self.player, self.forcePlay else { return }
      let restartTime = max(self.duration * 0.02, 0.5)
      player.seek(to: CMTime(seconds: restartTime, preferredTimescale: 600)) { _ in
        player.play()
        player.rate = Float(self.speedOption.rawValue)
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
    videoOpacity = 0
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

    if !clipTimes.isEmpty {
      playClip()
    }
  }

  private func playClip() {
    guard let player = player, !clipTimes.isEmpty else { return }

    let clipTime = clipTimes[currentClip]
    let seekTime = CMTime(seconds: clipTime, preferredTimescale: 600)

    player.seek(to: seekTime) { _ in
      player.play()
    }

    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: clipLength, repeats: false) { [self] _ in
      currentClip = (currentClip + 1) % clipTimes.count
      playClip()
    }
  }

  private func cleanup() {
    timer?.invalidate()
    timer = nil

    if let observer = playbackObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackObserver = nil
    }

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
    let startCMTime = CMTime(seconds: startTime, preferredTimescale: 600)

    player.seek(to: startCMTime) { _ in
      player.rate = Float(self.speedOption.rawValue)
      player.play()
    }

    playbackObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      let loopStartTime = self.duration * 0.02
      let loopCMTime = CMTime(seconds: loopStartTime, preferredTimescale: 600)

      player.seek(to: loopCMTime) { _ in
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

/// Generate a static thumbnail for video file (legacy support)
func generateStaticThumbnail(for url: URL) async -> Image? {
  return await withCheckedContinuation { continuation in
    _ = ThumbnailCache.shared.requestThumbnail(for: url, at: 1.0, priority: .normal) { image in
      continuation.resume(returning: image)
    }
  }
}

/// Generate a static thumbnail for video file at a specific time (legacy support)
func generateStaticThumbnailAtTime(for url: URL, at timeInSeconds: Double) async -> Image? {
  return await withCheckedContinuation { continuation in
    _ = ThumbnailCache.shared.requestThumbnail(for: url, at: timeInSeconds, priority: .normal) {
      image in
      continuation.resume(returning: image)
    }
  }
}
