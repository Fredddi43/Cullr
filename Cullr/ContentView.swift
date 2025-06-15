// ContentView.swift

import AVFoundation
import AVKit
// MARK: — NoControlsPlayerView
import AppKit
import Cocoa
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreServices
import PhotosUI
import Quartz  // <-- Add this for Quick Look
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers  // For file type handling

// Global timeout function
func withTimeout<T>(_ seconds: TimeInterval, operation: @escaping () async throws -> T) async throws
  -> T
{
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }

    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw CancellationError()
    }

    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}

enum PlaybackMode: String, CaseIterable, Identifiable {
  case folderView = "Folder View Mode"
  case single = "Single Clip Mode"
  case sideBySide = "Side-by-Side Clips"
  case batchList = "Batch List Mode"
  var id: String { self.rawValue }
}

enum PlaybackType: String, CaseIterable, Identifiable {
  case clips = "Clips"
  case speed = "Speed"
  var id: String { self.rawValue }
}

enum SpeedOption: Double, CaseIterable, Identifiable {
  case x2 = 2.0
  case x4 = 4.0
  case x8 = 8.0
  case x12 = 12.0
  case x16 = 16.0
  case x24 = 24.0
  case x32 = 32.0

  var id: Double { self.rawValue }
  var displayName: String { "x\(Int(self.rawValue))" }
}

enum SortOption: String, CaseIterable, Identifiable {
  case name = "Name"
  case dateAdded = "Date Added"
  case dateModified = "Date Modified"
  case size = "Size"
  case duration = "Video Length"  // <-- Add this

  var id: String { self.rawValue }
}

enum FilterSizeOption: String, CaseIterable, Identifiable {
  case all = "All Sizes"
  case small = "< 100 MB"
  case medium = "100 MB - 1 GB"
  case large = "1 GB - 5 GB"
  case xlarge = "> 5 GB"

  var id: String { self.rawValue }

  func matches(sizeBytes: UInt64) -> Bool {
    let sizeMB = Double(sizeBytes) / (1024 * 1024)
    let sizeGB = sizeMB / 1024

    switch self {
    case .all: return true
    case .small: return sizeMB < 100
    case .medium: return sizeMB >= 100 && sizeGB < 1
    case .large: return sizeGB >= 1 && sizeGB < 5
    case .xlarge: return sizeGB >= 5
    }
  }
}

enum FilterLengthOption: String, CaseIterable, Identifiable {
  case all = "All Lengths"
  case short = "< 30 sec"
  case medium = "30 sec - 5 min"
  case long = "5 min - 30 min"
  case veryLong = "> 30 min"

  var id: String { self.rawValue }

  func matches(durationSeconds: Double) -> Bool {
    let minutes = durationSeconds / 60

    switch self {
    case .all: return true
    case .short: return durationSeconds < 30
    case .medium: return durationSeconds >= 30 && minutes < 5
    case .long: return minutes >= 5 && minutes < 30
    case .veryLong: return minutes >= 30
    }
  }
}

enum FilterResolutionOption: String, CaseIterable, Identifiable {
  case all = "All Resolutions"
  case sd = "SD (< 720p)"
  case hd = "HD (720p)"
  case fullHd = "Full HD (1080p)"
  case uhd4k = "4K (2160p)"
  case uhd8k = "8K+"

  var id: String { self.rawValue }

  func matches(resolution: String) -> Bool {
    switch self {
    case .all: return true
    case .sd:
      return resolution.contains("480") || resolution.contains("576")
        || (!resolution.contains("720") && !resolution.contains("1080")
          && !resolution.contains("2160") && !resolution.contains("4320"))
    case .hd: return resolution.contains("720")
    case .fullHd: return resolution.contains("1080")
    case .uhd4k: return resolution.contains("2160")
    case .uhd8k: return resolution.contains("4320") || resolution.contains("8K")
    }
  }
}

enum FilterFileTypeOption: String, CaseIterable, Identifiable {
  case all = "All Types"
  case mp4 = "MP4"
  case mov = "MOV"
  case avi = "AVI"
  case mkv = "MKV"
  case other = "Other"

  var id: String { self.rawValue }

  func matches(fileExtension: String) -> Bool {
    let ext = fileExtension.lowercased()
    switch self {
    case .all: return true
    case .mp4: return ext == "mp4" || ext == "m4v"
    case .mov: return ext == "mov"
    case .avi: return ext == "avi"
    case .mkv: return ext == "mkv"
    case .other: return !["mp4", "m4v", "mov", "avi", "mkv"].contains(ext)
    }
  }
}

struct NonFocusableTextFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.roundedBorder)
      .onAppear {
        if let window = NSApplication.shared.windows.first {
          window.makeFirstResponder(nil)
        }
      }
  }
}

// MARK: — Global Event Monitor for Hotkeys
class GlobalHotkeyMonitor: ObservableObject {
  private var localEventMonitor: Any?

  var onSpace: (() -> Void)?
  var onDelete: (() -> Void)?
  var onKeep: (() -> Void)?
  var deleteKey: String = "d"
  var keepKey: String = "k"

  func startMonitoring() {
    print("GlobalHotkeyMonitor: Starting monitoring")

    // Local event monitor (when app is focused)
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      print(
        "GlobalHotkeyMonitor: Local key event - keyCode: \(event.keyCode), char: '\(event.charactersIgnoringModifiers?.lowercased() ?? "")'"
      )

      if self.handleKeyEvent(event) {
        print("GlobalHotkeyMonitor: Event handled, returning nil")
        return nil  // Consume the event
      }
      return event  // Let the event continue
    }
  }

  func stopMonitoring() {
    print("GlobalHotkeyMonitor: Stopping monitoring")
    if let monitor = localEventMonitor {
      NSEvent.removeMonitor(monitor)
      localEventMonitor = nil
    }
  }

  private func handleKeyEvent(_ event: NSEvent) -> Bool {
    let keyChar = event.charactersIgnoringModifiers?.lowercased() ?? ""

    if event.keyCode == 49 {  // Spacebar
      print("GlobalHotkeyMonitor: Spacebar pressed")
      onSpace?()
      return true
    } else if keyChar == deleteKey.lowercased() {
      print("GlobalHotkeyMonitor: Delete key ('\(deleteKey)') pressed")
      onDelete?()
      return true
    } else if keyChar == keepKey.lowercased() {
      print("GlobalHotkeyMonitor: Keep key ('\(keepKey)') pressed")
      onKeep?()
      return true
    }

    return false
  }

  deinit {
    stopMonitoring()
  }
}

// MARK: — Quick Look Helper
class QuickLookPreviewCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  static let shared = QuickLookPreviewCoordinator()
  private var urls: [URL] = []
  private var currentIndex: Int = 0
  func preview(urls: [URL], startAt index: Int = 0) {
    self.urls = urls
    self.currentIndex = index
    NSApp.activate(ignoringOtherApps: true)
    if let panel = QLPreviewPanel.shared() {
      panel.delegate = self
      panel.dataSource = self
      panel.makeKeyAndOrderFront(nil)
      panel.reloadData()
      panel.currentPreviewItemIndex = index
    }
  }
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    return urls.count
  }
  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    return urls.indices.contains(index) ? urls[index] as QLPreviewItem : nil
  }
  // QLPreviewPanelDelegate conformance for panel control
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    return true
  }
  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    // No-op for now
  }
  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    // No-op for now
  }
}

// Replace VideoPlayer with custom implementation
struct CustomVideoPlayerView: NSViewRepresentable {
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

// Custom video player with controls for single view
struct CustomVideoPlayerWithControls: View {
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

  init(
    player: AVPlayer, mode: PlayerMode = .clips, onPreviousClip: (() -> Void)? = nil,
    onNextClip: (() -> Void)? = nil, onSpeedChange: ((SpeedOption) -> Void)? = nil,
    currentSpeed: SpeedOption? = nil, globalIsMuted: Binding<Bool>
  ) {
    self.player = player
    self.mode = mode
    self.onPreviousClip = onPreviousClip
    self.onNextClip = onNextClip
    self.onSpeedChange = onSpeedChange
    self.currentSpeed = currentSpeed
    self._globalIsMuted = globalIsMuted
  }

  var body: some View {
    VStack(spacing: 0) {
      // Video player
      CustomVideoPlayerView(player: player)
        .onAppear {
          setupTimeObserver()
          loadDuration()
          updatePlayingState()
          // Sync player mute state with global state
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
                // Store playing state and pause for clips mode only
                wasPlayingBeforeScrub = isPlaying
                if mode == .clips {
                  player.pause()
                }
              } else {
                // Seek and resume based on mode
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
          .onChange(of: sliderValue) { newValue in
            if isDragging {
              seek(to: newValue)
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

  private func setupTimeObserver() {
    removeTimeObserver()  // Clean up any existing observer
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
    // Sync with global state
    globalIsMuted = player.isMuted
  }

  private func togglePlayPause() {
    if mode == .speed {
      // For speed mode, check rate directly
      if player.rate > 0 {
        player.pause()
        player.rate = 0
        isPlaying = false  // Immediately update state
      } else {
        player.play()
        if let speed = currentSpeed {
          player.rate = Float(speed.rawValue)
        } else {
          player.rate = 1.0
        }
        isPlaying = true  // Immediately update state
      }
    } else {
      // For clips mode, normal play/pause
      if isPlaying {
        player.pause()
      } else {
        player.play()
      }
    }
    // Force immediate update
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      updatePlayingState()
    }
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

  private func timeString(from seconds: Double) -> String {
    guard seconds.isFinite && seconds >= 0 else { return "0:00" }
    let minutes = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", minutes, secs)
  }
}

// Fallback view for when video fails
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

struct ContentView: View {
  // MARK: — Basic State
  @State private var videoURLs: [URL] = []
  @State private var folderURL: URL? = nil
  @State private var folderAccessing: Bool = false
  @State private var isPrepared: Bool = false
  @State private var currentIndex: Int = 0
  @State private var player: AVPlayer? = nil
  @State private var sortOption: SortOption = .name
  @State private var sortAscending: Bool = true

  // MARK: — Filters
  @State private var filterSize: FilterSizeOption = .all
  @State private var filterLength: FilterLengthOption = .all
  @State private var filterResolution: FilterResolutionOption = .all
  @State private var filterFileType: FilterFileTypeOption = .all
  @State private var isTextFieldDisabled: Bool = true  // Start with text fields disabled
  @FocusState private var hotkeyFieldFocused: Bool
  @State private var deleteHotkey: String = "d"
  @State private var keepHotkey: String = "k"
  @State private var isMuted: Bool = true
  @State private var playbackMode: PlaybackMode = .folderView
  @State private var playbackType: PlaybackType = .clips
  @State private var speedOption: SpeedOption = .x2

  // MARK: — Selections
  @State private var batchSelection: [Bool] = []
  @State private var selectedURLs: Set<URL> = []  // For folder view selection
  @State private var selectionOrder: [URL] = []  // Track selection order
  @State private var staticThumbnails: [String: Image] = [:]  // Key: url+time for batch list static thumbnails

  // MARK: — Thumbnails
  static var thumbnailCache: [URL: Image] = [:]

  // MARK: — Media Info
  @State private var totalFilesText: String = ""
  @State private var totalSizeText: String = ""
  @State private var fileInfo:
    [URL: (size: String, duration: String, resolution: String, fps: String)] = [:]

  // MARK: — State
  @State private var isLoadingThumbnails: Bool = false
  @State private var thumbnailsToLoad: Int = 0
  @State private var thumbnailsLoaded: Int = 0
  @State private var hoveredBatchRow: URL? = nil
  @State private var hoverWorkItems: [URL: DispatchWorkItem] = [:]
  @State private var lastSelectedItem: URL? = nil

  // MARK: — Configuration
  @State private var numberOfClips: Int = 5
  @State private var clipLength: Int = 3
  @State private var tempNumberOfClips: Int = 5
  @State private var tempClipLength: Int = 3

  // Add these states to ContentView:
  @State private var showDeleteConfirmation = false
  @State private var filesPendingDeletion: [URL] = []

  // Add persistent player size
  @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220

  // Add this to ContentView state:
  @State private var viewReloadID = UUID()

  // Add to ContentView state:
  @State private var folderCollection: [URL] = []
  @State private var currentFolderIndex: Int = 0
  private var isFolderCollectionMode: Bool { folderCollection.count > 1 }

  // Global hotkey monitor
  @StateObject private var hotkeyMonitor = GlobalHotkeyMonitor()

  // MARK: — Computed Properties
  private var filteredVideoURLs: [URL] {
    return videoURLs.filter { url in
      // Size filter
      if filterSize != .all {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? UInt64
        else { return false }
        if !filterSize.matches(sizeBytes: size) { return false }
      }

      // Length filter
      if filterLength != .all {
        guard let info = fileInfo[url] else { return false }
        if let duration = ContentView.durationInSeconds(from: info.duration) {
          if !filterLength.matches(durationSeconds: duration) { return false }
        } else {
          return false
        }
      }

      // Resolution filter
      if filterResolution != .all {
        guard let info = fileInfo[url] else { return false }
        if !filterResolution.matches(resolution: info.resolution) { return false }
      }

      // File type filter
      if filterFileType != .all {
        if !filterFileType.matches(fileExtension: url.pathExtension) { return false }
      }

      return true
    }
  }

  var body: some View {
    ZStack {
      Color.clear
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
          DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
          }
        }
        .onAppear {
          configureWindowTransparency()
          // Re-enable text fields after a short delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isTextFieldDisabled = false
          }

          // Set up hotkey monitor
          hotkeyMonitor.onSpace = {
            if !hotkeyFieldFocused {
              handleGlobalSpacebar()
            }
          }
          hotkeyMonitor.onDelete = {
            if !hotkeyFieldFocused && (playbackMode == .single || playbackMode == .sideBySide) {
              deleteCurrentVideo()
            }
          }
          hotkeyMonitor.onKeep = {
            if !hotkeyFieldFocused && (playbackMode == .single || playbackMode == .sideBySide) {
              skipCurrentVideo()
            }
          }
          hotkeyMonitor.deleteKey = deleteHotkey
          hotkeyMonitor.keepKey = keepHotkey
          hotkeyMonitor.startMonitoring()
        }
        .onDisappear {
          hotkeyMonitor.stopMonitoring()
        }
        .onChange(of: deleteHotkey) { newValue in
          hotkeyMonitor.deleteKey = newValue
        }
        .onChange(of: keepHotkey) { newValue in
          hotkeyMonitor.keepKey = newValue
        }

      VStack(spacing: 0) {
        settingsBar
        Divider()

        if folderURL == nil {
          Spacer()
          Text("Select a folder to begin")
            .font(.headline)
          Spacer()
        } else {
          switch playbackMode {
          case .single:
            singleClipView()
          case .sideBySide:
            sideBySideClipsView()
          case .batchList:
            batchListView()
          case .folderView:
            folderView()
          }
        }
      }
      .id(viewReloadID)
      .alert(isPresented: $showDeleteConfirmation) {
        let fileCount = filesPendingDeletion.count
        let totalBytes = filesPendingDeletion.reduce(0) {
          $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? UInt64) ?? 0)
        }
        let totalSize = formatFileSize(bytes: totalBytes)
        let fileList = filesPendingDeletion.map { $0.lastPathComponent }.joined(separator: "\n")
        return Alert(
          title: Text("Delete \(fileCount) file\(fileCount == 1 ? "" : "s")?"),
          message: Text(
            "This will delete \(fileCount) file\(fileCount == 1 ? "" : "s") and free up \(totalSize):\n\n\(fileList)"
          ),
          primaryButton: .destructive(Text("Delete")) {
            Task {
              await processSelectedFiles(selected: Set(filesPendingDeletion))
              filesPendingDeletion = []
            }
          },
          secondaryButton: .cancel {
            filesPendingDeletion = []
          }
        )
      }

      // Folder Collection Bottom Bar
      if isFolderCollectionMode {
        VStack {
          Spacer()
          HStack {
            Button(action: previousFolder) {
              Image(systemName: "chevron.left")
              Text("Previous")
            }
            .disabled(currentFolderIndex == 0)
            Spacer()
            Text(folderURL?.lastPathComponent ?? "")
              .font(.headline)
            Spacer()
            Text("\(currentFolderIndex + 1) / \(folderCollection.count)")
              .font(.subheadline)
              .foregroundColor(.secondary)
            Spacer()
            Button(action: nextFolder) {
              Text("Next")
              Image(systemName: "chevron.right")
            }
            .disabled(currentFolderIndex >= folderCollection.count - 1)
          }
          .padding(.horizontal, 24)
          .padding(.vertical, 12)
          .background(.ultraThinMaterial)
          .cornerRadius(12)
          .shadow(radius: 8)
          .padding(.bottom, 12)
        }
        .transition(.move(edge: .bottom))
        .zIndex(10)
      }
    }
    .frame(minWidth: 1200, minHeight: 800)
  }

  // Folder navigation actions
  private func nextFolder() {
    guard currentFolderIndex < folderCollection.count - 1 else { return }
    currentFolderIndex += 1
    folderURL = folderCollection[currentFolderIndex]
    if folderURL!.startAccessingSecurityScopedResource() {
      folderAccessing = true
    }
    loadVideosAndThumbnails(from: folderURL!)
    if let window = NSApplication.shared.windows.first {
      window.title = folderURL!.lastPathComponent
    }
  }

  private func previousFolder() {
    guard currentFolderIndex > 0 else { return }
    currentFolderIndex -= 1
    folderURL = folderCollection[currentFolderIndex]
    if folderURL!.startAccessingSecurityScopedResource() {
      folderAccessing = true
    }
    loadVideosAndThumbnails(from: folderURL!)
    if let window = NSApplication.shared.windows.first {
      window.title = folderURL!.lastPathComponent
    }
  }

  // MARK: — Spacebar Handler
  private func handleGlobalSpacebar() {
    if playbackMode == .folderView {
      let selected = Array(selectedURLs)
      if !selected.isEmpty {
        // Use the most recently selected item
        if let lastSelected = selectionOrder.last,
          selected.contains(lastSelected)
        {
          let index = selected.firstIndex(of: lastSelected) ?? 0
          QuickLookPreviewCoordinator.shared.preview(urls: selected, startAt: index)
        } else {
          QuickLookPreviewCoordinator.shared.preview(urls: selected, startAt: 0)
        }
      }
    } else if playbackMode == .batchList {
      let selected = videoURLs.enumerated().filter { batchSelection[$0.offset] }.map { $0.element }
      if !selected.isEmpty {
        // Use the most recently selected item
        if let lastSelected = selectionOrder.last,
          selected.contains(lastSelected)
        {
          let index = selected.firstIndex(of: lastSelected) ?? 0
          QuickLookPreviewCoordinator.shared.preview(urls: selected, startAt: index)
        } else {
          QuickLookPreviewCoordinator.shared.preview(urls: selected, startAt: 0)
        }
      }
    }
  }

  // MARK: — Settings Bar
  private var settingsBar: some View {
    HStack(spacing: 8) {
      Button(folderURL == nil ? "Select Video Folder" : "Change Folder") {
        selectFolder()
      }
      .buttonStyle(.borderedProminent)

      HStack(spacing: 6) {
        HStack(spacing: 2) {
          Text("Type:").frame(width: 40, alignment: .leading)
          Picker("", selection: $playbackType) {
            ForEach(PlaybackType.allCases) { type in
              Text(type.rawValue).tag(type)
            }
          }
          .frame(width: 80)
        }

        if playbackType == .clips {
          HStack(spacing: 2) {
            Text("Clips:").frame(width: 40, alignment: .leading)
            Stepper(value: $tempNumberOfClips, in: 1...10) {
              Text("\(tempNumberOfClips)")
            }
            .frame(width: 60)
          }

          HStack(spacing: 2) {
            Text("Length:").frame(width: 50, alignment: .leading)
            Stepper(value: $tempClipLength, in: 1...10) {
              Text("\(tempClipLength)s")
            }
            .frame(width: 60)
          }
        } else {
          HStack(spacing: 2) {
            Text("Speed:").frame(width: 40, alignment: .leading)
            Picker("", selection: $speedOption) {
              ForEach(SpeedOption.allCases) { speed in
                Text(speed.displayName).tag(speed)
              }
            }
            .frame(width: 80)
          }
        }
        // (Slider removed from here)
        HStack(spacing: 2) {
          Text("Delete:").frame(width: 50, alignment: .leading)
          TextField(
            "",
            text: Binding(
              get: { deleteHotkey.uppercased() },
              set: { deleteHotkey = $0.uppercased() }
            ),
            onCommit: {
              DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
              }
            }
          )
          .frame(width: 36, height: 24)
          .multilineTextAlignment(.center)
          .textFieldStyle(.roundedBorder)
          .disabled(isTextFieldDisabled)
          .focused($hotkeyFieldFocused)
        }

        HStack(spacing: 2) {
          Text("Keep:").frame(width: 40, alignment: .leading)
          TextField(
            "",
            text: Binding(
              get: { keepHotkey.uppercased() },
              set: { keepHotkey = $0.uppercased() }
            ),
            onCommit: {
              DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
              }
            }
          )
          .frame(width: 36, height: 24)
          .multilineTextAlignment(.center)
          .textFieldStyle(.roundedBorder)
          .disabled(isTextFieldDisabled)
          .focused($hotkeyFieldFocused)
        }

        HStack(spacing: 4) {
          Toggle(isOn: $isMuted) {
            Text("Mute")
              .frame(minWidth: 36, alignment: .leading)
          }
          .toggleStyle(.switch)
          .frame(height: 24)
          .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
        }
      }
      .frame(height: 28)

      if !totalFilesText.isEmpty {
        Text(totalFilesText)
          .font(.subheadline)
        Text(totalSizeText)
          .font(.subheadline)
        Button("Go") {
          Task {
            numberOfClips = tempNumberOfClips
            clipLength = tempClipLength
            if let folder = folderURL {
              loadVideosAndThumbnails(from: folder)
              // Hidden view reload
              viewReloadID = UUID()
            }
          }
        }
        .buttonStyle(.borderedProminent)
      }

      Spacer()

      Picker("Mode:", selection: $playbackMode) {
        ForEach(
          playbackType == .clips
            ? [PlaybackMode.folderView, .batchList, .sideBySide, .single]
            : [PlaybackMode.folderView, .batchList, .single]
        ) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 600)
      .onChange(of: playbackMode) { newMode in
        if newMode != .folderView {
          Task {
            await initializeForCurrentMode()
          }
        } else {
          // When switching to folder view, sync selection
          syncBatchSelectionFromSelectedURLs()
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial)
    .tint(.blue)
  }

  private func sortVideos() {
    let fm = FileManager.default
    videoURLs.sort { url1, url2 in
      let result: Bool
      switch sortOption {
      case .name:
        result =
          url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
          == .orderedAscending
      case .dateAdded:
        let date1 =
          (try? fm.attributesOfItem(atPath: url1.path)[.creationDate] as? Date) ?? Date.distantPast
        let date2 =
          (try? fm.attributesOfItem(atPath: url2.path)[.creationDate] as? Date) ?? Date.distantPast
        result = date1 < date2
      case .dateModified:
        let date1 =
          (try? fm.attributesOfItem(atPath: url1.path)[.modificationDate] as? Date)
          ?? Date.distantPast
        let date2 =
          (try? fm.attributesOfItem(atPath: url2.path)[.modificationDate] as? Date)
          ?? Date.distantPast
        result = date1 < date2
      case .size:
        let size1 = (try? fm.attributesOfItem(atPath: url1.path)[.size] as? UInt64) ?? 0
        let size2 = (try? fm.attributesOfItem(atPath: url2.path)[.size] as? UInt64) ?? 0
        result = size1 < size2
      case .duration:
        // Use fileInfo if available, otherwise fallback to AVAsset
        let duration1: Double = {
          if let info = fileInfo[url1], let min = ContentView.durationInSeconds(from: info.duration)
          {
            return min
          } else {
            let asset = AVAsset(url: url1)
            return asset.duration.seconds
          }
        }()
        let duration2: Double = {
          if let info = fileInfo[url2], let min = ContentView.durationInSeconds(from: info.duration)
          {
            return min
          } else {
            let asset = AVAsset(url: url2)
            return asset.duration.seconds
          }
        }()
        result = duration1 < duration2
      }
      return sortAscending ? result : !result
    }
  }

  // MARK: — Folder View
  private func folderView() -> some View {
    ZStack {
      VStack(spacing: 0) {
        if folderURL != nil && (playbackMode == .folderView || playbackMode == .batchList) {
          HStack(alignment: .center) {
            HStack(spacing: 4) {
              Picker("Sort by:", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                  Text(option.rawValue).tag(option)
                }
              }
              .frame(width: 180)

              Button(action: { sortAscending.toggle() }) {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
              }
              .buttonStyle(.plain)
            }

            Spacer()

            // Filter Controls
            filterControls()

            Spacer()

            playerSizeSlider(compact: true)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(.ultraThinMaterial)
          .onChange(of: sortOption) { _ in
            sortVideos()
          }
          .onChange(of: sortAscending) { _ in
            sortVideos()
          }
        }

        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: playerPreviewSize), spacing: 8)], spacing: 8
          ) {
            ForEach(filteredVideoURLs, id: \.self) { url in
              VStack(spacing: 4) {
                if playbackType == .speed {
                  FolderSpeedPreview(
                    url: url,
                    isMuted: isMuted,
                    speedOption: speedOption
                  )
                  .frame(width: playerPreviewSize, height: playerPreviewSize * 0.5636)
                  .cornerRadius(8)
                  .overlay(
                    RoundedRectangle(cornerRadius: 8)
                      .stroke(
                        selectedURLs.contains(url) ? Color.accentColor : Color.clear, lineWidth: 2)
                  )
                  .contentShape(Rectangle())
                  .simultaneousGesture(
                    TapGesture(count: 2)
                      .onEnded { _ in
                        NSWorkspace.shared.selectFile(
                          url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                      }
                  )
                  .onTapGesture {
                    if selectedURLs.contains(url) {
                      selectedURLs.remove(url)
                      selectionOrder.removeAll { $0 == url }
                    } else {
                      selectedURLs.insert(url)
                      selectionOrder.append(url)
                    }
                    syncBatchSelectionFromSelectedURLs()
                  }
                  .onKeyPress(.space) {
                    if selectedURLs.contains(url) {
                      NSWorkspace.shared.open(url)
                      return .handled
                    }
                    return .ignored
                  }
                } else {
                  FolderHoverLoopPreview(
                    url: url,
                    isMuted: isMuted,
                    numberOfClips: numberOfClips,
                    clipLength: clipLength,
                    playbackType: playbackType,
                    speedOption: speedOption
                  )
                  .frame(width: playerPreviewSize, height: playerPreviewSize * 0.5636)
                  .cornerRadius(8)
                  .overlay(
                    RoundedRectangle(cornerRadius: 8)
                      .stroke(
                        selectedURLs.contains(url) ? Color.accentColor : Color.clear, lineWidth: 2)
                  )
                  .contentShape(Rectangle())
                  .simultaneousGesture(
                    TapGesture(count: 2)
                      .onEnded { _ in
                        NSWorkspace.shared.selectFile(
                          url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                      }
                  )
                  .onTapGesture {
                    if selectedURLs.contains(url) {
                      selectedURLs.remove(url)
                      selectionOrder.removeAll { $0 == url }
                    } else {
                      selectedURLs.insert(url)
                      selectionOrder.append(url)
                    }
                    syncBatchSelectionFromSelectedURLs()
                  }
                  .onKeyPress(.space) {
                    if selectedURLs.contains(url) {
                      NSWorkspace.shared.open(url)
                      return .handled
                    }
                    return .ignored
                  }
                }
                if let info = fileInfo[url] {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                      .font(.headline)
                    Text("\(info.size) • \(info.duration) • \(info.resolution) • \(info.fps)")
                      .font(.subheadline)
                      .foregroundColor(.secondary)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 16)
                  .padding(.vertical, 2)
                  .padding(.bottom, isFolderCollectionMode ? 32 : 0)
                }
              }
            }
          }
          .padding(8)
        }
        Spacer()
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(selectedURLs.count) files selected")
              .foregroundColor(.secondary)
            if filteredVideoURLs.count != videoURLs.count {
              Text("Showing \(filteredVideoURLs.count) of \(videoURLs.count) files")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          Spacer()
          Button("Delete Selected Files") {
            filesPendingDeletion = Array(selectedURLs)
            showDeleteConfirmation = true
          }
          .buttonStyle(.borderedProminent)
          .disabled(selectedURLs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .padding(.bottom, isFolderCollectionMode ? 60 : 0)
        .background(.ultraThinMaterial)
      }
      if isLoadingThumbnails {
        loadingOverlay
      }
    }
  }

  // MARK: — Load Videos
  private func loadVideos(from folder: URL) {
    stopPlayback()
    videoURLs.removeAll()
    currentIndex = 0
    batchSelection.removeAll()
    selectedURLs.removeAll()
    fileInfo.removeAll()

    let fm = FileManager.default
    let allowedExtensions = ["mp4", "mov", "m4v", "avi", "mpg", "mpeg"]

    do {
      let contents = try fm.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )

      videoURLs = contents.filter { url in
        allowedExtensions.contains(url.pathExtension.lowercased())
      }

      sortVideos()  // Apply initial sorting
      batchSelection = Array(repeating: false, count: videoURLs.count)

      // Calculate total size and get file info
      var totalSize: UInt64 = 0
      for url in videoURLs {
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? UInt64
        {
          totalSize += size

          Task {
            await loadFileInfo(for: url)
          }
        }
      }

      totalFilesText = "Total Files: \(videoURLs.count)"
      totalSizeText = "Total Size: \(formatFileSize(bytes: totalSize))"

      // Update window title
      if let window = NSApplication.shared.windows.first {
        window.title = folder.lastPathComponent
      }

      // Ensure we're in folder view mode
      playbackMode = .folderView

    } catch {
      print("Error loading directory contents: \(error.localizedDescription)")
    }
  }

  private func loadFileInfo(for url: URL) async {
    let asset = AVURLAsset(url: url)
    do {
      let duration = try await asset.load(.duration)
      let tracks = try await asset.load(.tracks)

      var resolution = "Unknown"
      var fps = "Unknown"
      if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
        let size = try await videoTrack.load(.naturalSize)
        resolution = "\(Int(size.width))×\(Int(size.height))"

        let frameRate = try await videoTrack.load(.nominalFrameRate)
        fps = String(format: "%.2f fps", frameRate)
      }

      let durationText = String(
        format: "%d:%02d", Int(duration.seconds) / 60, Int(duration.seconds) % 60)
      let sizeText = formatFileSize(
        bytes: try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0)

      await MainActor.run {
        fileInfo[url] = (size: sizeText, duration: durationText, resolution: resolution, fps: fps)
      }
    } catch {
      print("Error loading file info for \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }

  // MARK: — Video Playback
  private func prepareCurrentVideo() async {
    stopPlayback()
    guard currentIndex < videoURLs.count else {
      print(
        "[Cullr] prepareCurrentVideo: currentIndex (", currentIndex,
        ") out of bounds (videoURLs.count = ", videoURLs.count, ")")
      return
    }
    let url = videoURLs[currentIndex]
    print("[Cullr] prepareCurrentVideo: Using url at index", currentIndex, ":", url.path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      print("[Cullr] prepareCurrentVideo: File does not exist at", url.path)
      return
    }
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    await MainActor.run {
      player = AVPlayer(playerItem: item)
      player?.isMuted = isMuted
      if playbackMode == .single {
        player?.play()
      }
      if player == nil {
        print("[Cullr] prepareCurrentVideo: Failed to create AVPlayer for", url.path)
      }
    }
  }

  private func stopPlayback() {
    player?.pause()
    player = nil
  }

  // MARK: — Process Selected Files
  private func processSelectedFiles(selected: Set<URL>) async {
    print("processSelectedFiles called with \(selected.count) files")
    guard let folder = folderURL else {
      print("processSelectedFiles: no folderURL")
      return
    }

    var failedFiles: [String] = []

    for url in selected {
      print("processSelectedFiles: Attempting to delete \(url.lastPathComponent)")
      print(
        "processSelectedFiles: File exists: \(FileManager.default.fileExists(atPath: url.path))")

      // Try to access the security scoped resource if needed
      let accessing = url.startAccessingSecurityScopedResource()
      defer {
        if accessing {
          url.stopAccessingSecurityScopedResource()
        }
      }

      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        print("processSelectedFiles: Successfully moved to trash: \(url.lastPathComponent)")
      } catch {
        print("processSelectedFiles: Failed to trash, trying direct removal: \(error)")
        do {
          try FileManager.default.removeItem(at: url)
          print("processSelectedFiles: Successfully removed: \(url.lastPathComponent)")
        } catch {
          print("processSelectedFiles: Failed to remove: \(error)")
          failedFiles.append(url.lastPathComponent)
        }
      }
    }

    // Show alert for failed deletions
    if !failedFiles.isEmpty {
      await MainActor.run {
        let alert = NSAlert()
        alert.messageText = "Some Files Could Not Be Deleted"
        alert.informativeText = "Failed to delete: \(failedFiles.joined(separator: ", "))"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
      }
    }

    loadVideos(from: folder)
    selectedURLs.removeAll()
  }

  // MARK: — Folder Selection
  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose folder(s) containing video files"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.folder]
    panel.begin { response in
      if response == .OK {
        let urls = panel.urls
        if urls.count > 1 {
          // Multiple folders selected
          folderCollection = urls
          currentFolderIndex = 0
          folderURL = folderCollection.first
          isPrepared = false
          if folderURL!.startAccessingSecurityScopedResource() {
            folderAccessing = true
            loadVideosAndThumbnails(from: folderURL!)
          }
          if let window = NSApplication.shared.windows.first {
            window.title = folderURL!.lastPathComponent
          }
        } else if let url = urls.first {
          // Single folder selected: scan for subfolders
          let fm = FileManager.default
          var subfolders: [URL] = []
          if let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
          {
            subfolders = contents.filter {
              (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.sorted {
              $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                == .orderedAscending
            }
          }
          if subfolders.isEmpty {
            // No subfolders, just open the folder
            folderCollection = [url]
            currentFolderIndex = 0
            folderURL = url
            isPrepared = false
            if url.startAccessingSecurityScopedResource() {
              folderAccessing = true
              loadVideosAndThumbnails(from: url)
            }
            if let window = NSApplication.shared.windows.first {
              window.title = url.lastPathComponent
            }
          } else {
            // Check for video files in root
            let allowedExtensions = ["mp4", "mov", "m4v", "avi", "mpg", "mpeg"]
            let rootVideos =
              (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.filter {
                allowedExtensions.contains($0.pathExtension.lowercased())
              } ?? []
            folderCollection = rootVideos.isEmpty ? subfolders : [url] + subfolders
            currentFolderIndex = 0
            folderURL = folderCollection.first
            isPrepared = false
            loadVideosAndThumbnails(from: folderURL!)
            if let window = NSApplication.shared.windows.first {
              window.title = folderURL!.lastPathComponent
            }
          }
        }
      } else {
        if let window = NSApplication.shared.windows.first {
          window.title = "Cullr"
        }
      }
    }
  }

  private func relinquishFolderAccess() {
    if let url = folderURL, folderAccessing {
      url.stopAccessingSecurityScopedResource()
    }
    folderAccessing = false
  }

  // MARK: — Load Videos and Thumbnails
  private func loadVideosAndThumbnails(from folder: URL) {
    stopPlayback()
    videoURLs.removeAll()
    currentIndex = 0
    batchSelection.removeAll()
    selectedURLs.removeAll()
    fileInfo.removeAll()
    staticThumbnails.removeAll()
    isLoadingThumbnails = true
    thumbnailsLoaded = 0
    thumbnailsToLoad = 0

    let fm = FileManager.default
    let allowedExtensions = ["mp4", "mov", "m4v", "avi", "mpg", "mpeg"]

    do {
      let contents = try fm.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )

      videoURLs = contents.filter { url in
        allowedExtensions.contains(url.pathExtension.lowercased())
      }

      sortVideos()  // Apply initial sorting
      batchSelection = Array(repeating: false, count: videoURLs.count)

      // Calculate total size and get file info
      var totalSize: UInt64 = 0
      for url in videoURLs {
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? UInt64
        {
          totalSize += size
          Task {
            await loadFileInfo(for: url)
          }
        }
      }

      totalFilesText = "Total Files: \(videoURLs.count)"
      totalSizeText = "Total Size: \(formatFileSize(bytes: totalSize))"

      // Update window title
      if let window = NSApplication.shared.windows.first {
        window.title = folder.lastPathComponent
      }

      // Sync temp values to real values when loading a folder
      tempNumberOfClips = numberOfClips
      tempClipLength = clipLength

      // Pre-generate all thumbnails for all files and clips
      let allClipTimes: [(URL, [Double])]
      if playbackType == .clips {
        allClipTimes = videoURLs.map { url in
          let times = [0.02] + getClipTimes(for: url, count: numberOfClips)
          return (url, times)
        }
      } else {
        allClipTimes = videoURLs.map { url in (url, [0.02]) }
      }
      thumbnailsToLoad = allClipTimes.reduce(0) { $0 + $1.1.count }
      thumbnailsLoaded = 0
      for (url, times) in allClipTimes {
        for time in times {
          generateStaticThumbnail(for: url, at: time, countForLoading: true)
        }
      }

      // Ensure we're in folder view mode
      //playbackMode = .folderView

    } catch {
      print("Error loading directory contents: \(error.localizedDescription)")
    }
  }

  // MARK: — Static Thumbnail Generation (Batch List, with loading count)
  private func generateStaticThumbnail(for url: URL, at time: Double, countForLoading: Bool = false)
  {
    // Add a small delay to prevent overwhelming the system
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.01) {
      let asset = AVAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 600, height: 338)  // Reduced size for better performance
      generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
      generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

      // Use the provided time directly since we already set it to 0.02 for speed mode in loadVideosAndThumbnails
      let actualTime = max(time, 0.1)  // Ensure we don't try to get frame at 0
      let cmTime = CMTime(seconds: actualTime, preferredTimescale: 600)

      if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
        let image = Image(decorative: cgImage, scale: 1.0)
        DispatchQueue.main.async {
          staticThumbnails[ContentView.thumbnailKey(url: url, time: time)] = image
          if countForLoading {
            thumbnailsLoaded += 1
            if thumbnailsLoaded >= thumbnailsToLoad {
              isLoadingThumbnails = false
            }
          }
        }
      } else if countForLoading {
        DispatchQueue.main.async {
          thumbnailsLoaded += 1
          if thumbnailsLoaded >= thumbnailsToLoad {
            isLoadingThumbnails = false
          }
        }
      }
    }
  }

  // MARK: — Loading Overlay
  private var loadingOverlay: some View {
    ZStack {
      Color.black.opacity(0.4).ignoresSafeArea()
      VStack(spacing: 16) {
        ProgressView(value: Double(thumbnailsLoaded), total: Double(max(thumbnailsToLoad, 1)))
          .progressViewStyle(LinearProgressViewStyle())
          .frame(width: 240)
        Text("Loading clips… (\(thumbnailsLoaded)/\(thumbnailsToLoad))")
          .foregroundColor(.white)
          .font(.headline)
      }
    }
  }

  // MARK: — Actions
  private func deleteCurrentVideo() {
    print("deleteCurrentVideo called")
    print("currentIndex: \(currentIndex), videoURLs.count: \(videoURLs.count)")
    print("folderURL: \(String(describing: folderURL))")
    print("folderAccessing: \(folderAccessing)")

    guard currentIndex < videoURLs.count else {
      print("deleteCurrentVideo: currentIndex out of bounds")
      return
    }

    guard let folder = folderURL else {
      print("deleteCurrentVideo: no folderURL")
      return
    }

    let url = videoURLs[currentIndex]
    print("deleteCurrentVideo: Attempting to delete \(url.lastPathComponent)")
    print("deleteCurrentVideo: File exists: \(FileManager.default.fileExists(atPath: url.path))")
    print("deleteCurrentVideo: File path: \(url.path)")

    // Try to access the security scoped resource if needed
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing {
        url.stopAccessingSecurityScopedResource()
      }
    }

    do {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      print("deleteCurrentVideo: Successfully moved to trash: \(url.lastPathComponent)")
    } catch {
      print("deleteCurrentVideo: Failed to trash, trying direct removal: \(error)")
      do {
        try FileManager.default.removeItem(at: url)
        print("deleteCurrentVideo: Successfully removed: \(url.lastPathComponent)")
      } catch {
        print("deleteCurrentVideo: Failed to remove: \(error)")
        // Show an alert to the user
        DispatchQueue.main.async {
          let alert = NSAlert()
          alert.messageText = "Failed to Delete File"
          alert.informativeText =
            "Could not delete \(url.lastPathComponent): \(error.localizedDescription)"
          alert.alertStyle = .warning
          alert.addButton(withTitle: "OK")
          alert.runModal()
        }
        return
      }
    }

    Task {
      await advanceToNextVideo()
    }
  }

  private func skipCurrentVideo() {
    Task {
      await advanceToNextVideo()
    }
  }

  private func advanceToNextVideo() async {
    stopPlayback()
    videoURLs.remove(at: currentIndex)
    if currentIndex >= videoURLs.count {
      resetToSettings()
    } else {
      await prepareCurrentVideo()
    }
  }

  private func initializeForCurrentMode() async {
    guard !videoURLs.isEmpty else { return }
    // Do NOT reset batchSelection or selectedURLs here
    syncBatchSelectionFromSelectedURLs()
    syncSelectedURLsFromBatchSelection()
    currentIndex = 0
    isPrepared = true
    if playbackMode == .single || playbackMode == .sideBySide {
      await prepareCurrentVideo()
    }
  }

  private func resetToSettings() {
    stopPlayback()
    isPrepared = false
    if let folder = folderURL {
      loadVideos(from: folder)
    }
  }

  // MARK: — Window Transparency (revert to original, no contentView replacement)
  private func configureWindowTransparency() {
    if let window = NSApplication.shared.windows.first {
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .visible
      window.isOpaque = false
      window.backgroundColor = .clear
      window.isMovableByWindowBackground = true
      window.title = folderURL?.lastPathComponent ?? "Cullr"
      window.makeFirstResponder(nil)  // Ensure no text field gets focus
    }
  }

  private func formatFileSize(bytes: UInt64) -> String {
    if bytes >= 1_000_000_000 {
      return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    } else if bytes >= 1_000_000 {
      return String(format: "%.2f MB", Double(bytes) / 1_000_000)
    } else if bytes >= 1_000 {
      return String(format: "%.2f KB", Double(bytes) / 1_000)
    } else {
      return "\(bytes) bytes"
    }
  }

  // MARK: — Single Clip View
  private func singleClipView() -> some View {
    VStack(spacing: 0) {
      if currentIndex < videoURLs.count {
        let url = videoURLs[currentIndex]
        if !FileManager.default.fileExists(atPath: url.path) {
          VStack {
            Spacer()
            Text("File does not exist: \(url.lastPathComponent)")
              .foregroundColor(.red)
              .font(.headline)
            Spacer()
          }
        } else {
          if playbackType == .speed {
            SingleSpeedPlayerFill(
              url: url,
              speedOption: $speedOption,
              isMuted: $isMuted
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .id(url)
          } else {
            SingleClipLoopingPlayerFill(
              url: url,
              numberOfClips: numberOfClips,
              clipLength: clipLength,
              isMuted: $isMuted
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .id(url)
          }
          if let info = fileInfo[url] {
            VStack(alignment: .leading, spacing: 4) {
              Text(url.lastPathComponent)
                .font(.headline)
              Text("\(info.size) • \(info.duration) • \(info.resolution) • \(info.fps)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
          } else {
            EmptyView()
          }
          Spacer(minLength: 0)
          HStack {
            Button {
              deleteCurrentVideo()
            } label: {
              Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(KeyEquivalent(deleteHotkey.lowercased().first ?? "d"))
            .buttonStyle(.bordered)
            Spacer()
            Button {
              skipCurrentVideo()
            } label: {
              Label("Keep", systemImage: "checkmark.circle")
            }
            .keyboardShortcut(KeyEquivalent(keepHotkey.lowercased().first ?? "k"))
            .buttonStyle(.borderedProminent)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .padding(.bottom, isFolderCollectionMode ? 60 : 0)
          .background(.ultraThinMaterial)
        }
      } else {
        VStack {
          Spacer()
          Text("No video at current index (\(currentIndex)).")
            .foregroundColor(.red)
            .font(.headline)
          Spacer()
        }
      }
    }
  }

  // MARK: — Single Clip Looping Player (Fill Layout)
  struct SingleClipLoopingPlayerFill: View {
    let url: URL
    let numberOfClips: Int
    let clipLength: Int
    @Binding var isMuted: Bool
    @State private var player: AVPlayer? = nil
    @State private var startTimes: [Double] = []
    @State private var currentClip: Int = 0
    @State private var duration: Double = 0
    @State private var boundaryObserver: Any? = nil
    @State private var didAppear: Bool = false
    @State private var showFallback: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isUserControlling: Bool = false
    @State private var periodicTimeObserver: Any? = nil
    @State private var isStopping: Bool = false
    @State private var isInitializing: Bool = true
    @State private var isSeeking: Bool = false
    @State private var lastSeekTime: Double = 0

    var body: some View {
      Group {
        if showFallback || errorMessage != nil {
          VideoFallbackView(
            url: url,
            errorMessage: errorMessage ?? "Unknown error"
          )
        } else if let player = player, !startTimes.isEmpty {
          CustomVideoPlayerWithControls(
            player: player,
            mode: .clips,
            onPreviousClip: previousClip,
            onNextClip: nextClip,
            globalIsMuted: $isMuted
          )
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .cornerRadius(12)
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
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cornerRadius(12)
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
      let d = asset.duration.seconds
      let times = computeStartTimes(duration: d, count: numberOfClips)
      duration = d
      startTimes = times
      let item = AVPlayerItem(asset: asset)
      let newPlayer = AVPlayer(playerItem: item)
      newPlayer.isMuted = isMuted
      newPlayer.actionAtItemEnd = .none
      player = newPlayer
    }

    private func playClip(index: Int) {
      guard let player = player, !startTimes.isEmpty else { return }
      let start = startTimes[index]
      let end = start + Double(clipLength)

      // Remove previous observer
      if let observer = boundaryObserver {
        player.removeTimeObserver(observer)
        boundaryObserver = nil
      }

      // Seek to start position and play
      isSeeking = true
      player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { _ in
        isSeeking = false
        lastSeekTime = start

        // Add boundary observer for end of clip
        let boundary = CMTime(seconds: end, preferredTimescale: 600)
        self.boundaryObserver = player.addBoundaryTimeObserver(
          forTimes: [NSValue(time: boundary)], queue: .main
        ) {
          if !self.isUserControlling {
            // Move to next clip
            self.currentClip = (self.currentClip + 1) % self.startTimes.count
            self.playClip(index: self.currentClip)
          }
        }

        // Start playback
        player.play()
      }
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

    private func previousClip() {
      guard !startTimes.isEmpty, let player = player else { return }

      let currentTime = player.currentTime().seconds
      let closestIndex = findClosestClipIndex(to: currentTime)

      // If we're at the first clip, go to the last one
      if closestIndex == 0 {
        currentClip = startTimes.count - 1
      } else {
        currentClip = closestIndex - 1
      }

      playClip(index: currentClip)
    }

    private func nextClip() {
      guard !startTimes.isEmpty, let player = player else { return }

      let currentTime = player.currentTime().seconds
      let closestIndex = findClosestClipIndex(to: currentTime)

      // If we're at the last clip, go to the first one
      if closestIndex >= startTimes.count - 1 {
        currentClip = 0
      } else {
        currentClip = closestIndex + 1
      }

      playClip(index: currentClip)
    }

    private func cleanup() {
      stopLoopingClips()
      if let observer = periodicTimeObserver {
        player?.removeTimeObserver(observer)
        periodicTimeObserver = nil
      }
      player?.pause()
      player = nil
      didAppear = false
      isUserControlling = false
      isStopping = false
      isInitializing = true
      isSeeking = false
      lastSeekTime = 0
    }

    private func computeStartTimes(duration: Double, count: Int) -> [Double] {
      guard duration > 0, count > 0 else { return [] }
      let start = duration * 0.02  // Start at 2% of video
      let interval = (duration * 0.96) / Double(count)  // Distribute remaining 96% evenly
      return (0..<count).map { start + Double($0) * interval }
    }

    private func startLoopingClips() {
      if !isStopping {
        isStopping = true
        stopLoopingClips()
        guard !startTimes.isEmpty, let player = player else {
          isStopping = false
          return
        }
        currentClip = 0
        playClip(index: currentClip)
        isStopping = false
      }
    }

    private func stopLoopingClips() {
      if let player = player, let observer = boundaryObserver {
        player.removeTimeObserver(observer)
        boundaryObserver = nil
      }
    }
  }

  // MARK: — Side-by-Side Clips View
  private func sideBySideClipsView() -> some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        playerSizeSlider(compact: true)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      if currentIndex < videoURLs.count {
        let url = videoURLs[currentIndex]
        GeometryReader { geometry in
          let columns = max(1, Int(geometry.size.width / (playerPreviewSize + 16)))
          let gridItems = Array(repeating: GridItem(.flexible(), spacing: 16), count: columns)
          ScrollView {
            LazyVGrid(columns: gridItems, spacing: 16) {
              if playbackType == .speed {
                // In speed mode, show a single preview
                SpeedClipPreview(
                  url: url,
                  speedOption: speedOption,
                  isMuted: isMuted
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(width: playerPreviewSize, height: playerPreviewSize * 0.5636)
                .cornerRadius(12)
              } else {
                // In clips mode, show multiple previews
                let times = getClipTimes(for: url, count: numberOfClips)
                ForEach(Array(times.enumerated()), id: \.offset) { (i, start) in
                  VideoClipPreview(
                    url: url, startTime: start, length: Double(clipLength), isMuted: isMuted
                  )
                  .aspectRatio(16.0 / 9.0, contentMode: .fit)
                  .frame(width: playerPreviewSize, height: playerPreviewSize * 0.5636)
                  .cornerRadius(12)
                }
              }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .id(url)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity * 0.7)
        if let info = fileInfo[url] {
          VStack(alignment: .leading, spacing: 4) {
            Text(url.lastPathComponent)
              .font(.headline)
            Text("\(info.size) • \(info.duration) • \(info.resolution) • \(info.fps)")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
        }
        Spacer(minLength: 0)
        HStack {
          Button {
            deleteCurrentVideo()
          } label: {
            Label("Delete", systemImage: "trash")
          }
          .keyboardShortcut(KeyEquivalent(deleteHotkey.lowercased().first ?? "d"))
          .buttonStyle(.bordered)
          Spacer()
          Button {
            skipCurrentVideo()
          } label: {
            Label("Keep", systemImage: "checkmark.circle")
          }
          .keyboardShortcut(KeyEquivalent(keepHotkey.lowercased().first ?? "k"))
          .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .padding(.bottom, isFolderCollectionMode ? 60 : 0)
        .background(.ultraThinMaterial)
      }
    }
  }

  // MARK: — Batch List View
  private func batchListView() -> some View {
    Group {
      ZStack(alignment: .bottom) {
        VStack(spacing: 0) {
          if folderURL != nil {
            HStack(alignment: .center) {
              HStack(spacing: 4) {
                Picker("Sort by:", selection: $sortOption) {
                  ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                  }
                }
                .frame(width: 180)

                Button(action: { sortAscending.toggle() }) {
                  Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.plain)
              }

              Spacer()

              // Filter Controls
              filterControls()

              Spacer()

              playerSizeSlider(compact: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .onChange(of: sortOption) { _ in
              sortVideos()
            }
            .onChange(of: sortAscending) { _ in
              sortVideos()
            }
          }

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(filteredVideoURLs, id: \.self) { url in
                BatchListRowView(
                  url: url,
                  times: getClipTimes(for: url, count: numberOfClips),
                  staticThumbnails: staticThumbnails,
                  isMuted: isMuted,
                  playbackType: playbackType,
                  speedOption: speedOption,
                  isSelected: Binding(
                    get: { batchSelection[videoURLs.firstIndex(of: url) ?? 0] },
                    set: { newValue in
                      batchSelection[videoURLs.firstIndex(of: url) ?? 0] = newValue
                      if newValue {
                        selectionOrder.append(url)
                      } else {
                        selectionOrder.removeAll { $0 == url }
                      }
                      syncSelectedURLsFromBatchSelection()
                    }
                  ),
                  fileInfo: fileInfo[url],
                  isRowHovered: hoveredBatchRow == url,
                  onHoverChanged: { hovering in
                    if hovering {
                      hoveredBatchRow = url
                    } else {
                      hoveredBatchRow = nil
                    }
                  }
                )
                .simultaneousGesture(
                  TapGesture(count: 2)
                    .onEnded { _ in
                      NSWorkspace.shared.selectFile(
                        url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                )
                .onKeyPress(.space) {
                  if batchSelection[videoURLs.firstIndex(of: url) ?? 0] {
                    NSWorkspace.shared.open(url)
                    return .handled
                  }
                  return .ignored
                }
              }
            }
          }
          .safeAreaInset(edge: .bottom) {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("\(batchSelection.filter { $0 }.count) files selected")
                  .foregroundColor(.secondary)
                if filteredVideoURLs.count != videoURLs.count {
                  Text("Showing \(filteredVideoURLs.count) of \(videoURLs.count) files")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
              }
              Spacer()
              Button("Delete Selected Files") {
                filesPendingDeletion = zip(videoURLs, batchSelection).filter { $0.1 }.map { $0.0 }
                showDeleteConfirmation = true
              }
              .buttonStyle(.borderedProminent)
              .disabled(!batchSelection.contains(true))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, isFolderCollectionMode ? 60 : 0)
            .background(.ultraThinMaterial)
          }
        }
      }
      if isLoadingThumbnails {
        loadingOverlay
      }
    }
  }

  struct BatchListRowView: View {
    let url: URL
    let times: [Double]
    let staticThumbnails: [String: Image]
    let isMuted: Bool
    let playbackType: PlaybackType
    let speedOption: SpeedOption
    @Binding var isSelected: Bool
    let fileInfo: (size: String, duration: String, resolution: String, fps: String)?
    let isRowHovered: Bool
    let onHoverChanged: (Bool) -> Void
    @State private var thumbnail: Image? = nil
    @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220

    var body: some View {
      HStack {
        HStack(spacing: 8) {
          if playbackType == .clips {
            ForEach(times, id: \.self) { time in
              HoverPreviewCard(
                url: url,
                thumbnail: staticThumbnails[ContentView.thumbnailKey(url: url, time: time)],
                isMuted: isMuted,
                startTime: time,
                forcePlay: isRowHovered,
                playbackType: playbackType,
                speedOption: speedOption
              )
              .frame(width: playerPreviewSize * 0.545, height: playerPreviewSize * 0.309)
              .cornerRadius(10)
            }
          } else {
            // In speed mode, show only one preview at 2% offset
            HoverPreviewCard(
              url: url,
              thumbnail: thumbnail,
              isMuted: isMuted,
              startTime: 0.02,  // Use 2% offset for both thumbnail and playback
              forcePlay: isRowHovered,
              playbackType: playbackType,
              speedOption: speedOption
            )
            .frame(width: playerPreviewSize * 0.545, height: playerPreviewSize * 0.309)
            .cornerRadius(10)
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(url.lastPathComponent)
            .lineLimit(2)
            .truncationMode(.middle)
            .font(.body)
          if let info = fileInfo {
            Text("\(info.size) • \(info.duration)")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .frame(width: playerPreviewSize, alignment: .leading)
        Spacer()
      }
      .contentShape(Rectangle())
      .onHover { hovering in
        onHoverChanged(hovering)
      }
      .onTapGesture {
        isSelected.toggle()
      }
      .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
      .padding(.vertical, 8)
      .padding(.horizontal, 16)
      .task {
        // Load thumbnail exactly like folder view
        if let cached = ContentView.thumbnailCache[url] {
          thumbnail = cached
        } else {
          do {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 338)  // Reduced size for better performance
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            // Use the same 2% offset as the video preview, but ensure it's not 0
            let time = max(asset.duration.seconds * 0.02, 0.1)
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
            let image = Image(decorative: cgImage, scale: 1.0)
            ContentView.thumbnailCache[url] = image
            thumbnail = image
          } catch {
            print(
              "Error loading thumbnail for \(url.lastPathComponent): \(error.localizedDescription)")
          }
        }
      }
    }
  }

  // MARK: — Static Thumbnail Generation (Batch List)
  static func thumbnailKey(url: URL, time: Double) -> String {
    return url.absoluteString + "_" + String(format: "%.2f", time)
  }
  private func getClipTimes(for url: URL, count: Int) -> [Double] {
    let asset = AVAsset(url: url)
    let duration = asset.duration.seconds
    guard duration > 0, count > 0 else { return Array(repeating: 0.0, count: count) }
    let step = duration / Double(count + 1)
    return (1...count).map { Double($0) * step }
  }

  // Add these helpers to ContentView:
  private func syncBatchSelectionFromSelectedURLs() {
    for (i, url) in videoURLs.enumerated() {
      batchSelection[i] = selectedURLs.contains(url)
    }
  }

  private func syncSelectedURLsFromBatchSelection() {
    selectedURLs = Set(zip(videoURLs, batchSelection).filter { $0.1 }.map { $0.0 })
  }

  // Add this view for the player size slider, to be used in all non-single views
  @ViewBuilder
  private func playerSizeSlider(compact: Bool = false) -> some View {
    HStack {
      Spacer()
      HStack(spacing: 8) {
        Slider(value: $playerPreviewSize, in: 100...600, step: 1)
          .frame(width: 160)
        Text(LocalizedStringKey("Player Size: "))
          .font(.caption)
          .foregroundColor(.secondary)
        Text("\(Int(playerPreviewSize))")
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
      .padding(.trailing, 0)
      .padding(.top, compact ? 0 : 4)
    }
  }

  // MARK: — Filter Controls
  @ViewBuilder
  private func filterControls() -> some View {
    HStack(spacing: 8) {
      // Size Filter
      Picker("Size", selection: $filterSize) {
        ForEach(FilterSizeOption.allCases) { option in
          Text(option.rawValue).tag(option)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 140)

      // Length Filter
      Picker("Length", selection: $filterLength) {
        ForEach(FilterLengthOption.allCases) { option in
          Text(option.rawValue).tag(option)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 140)

      // Resolution Filter
      Picker("Resolution", selection: $filterResolution) {
        ForEach(FilterResolutionOption.allCases) { option in
          Text(option.rawValue).tag(option)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 160)

      // File Type Filter
      Picker("Type", selection: $filterFileType) {
        ForEach(FilterFileTypeOption.allCases) { option in
          Text(option.rawValue).tag(option)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 100)

      // Clear Filters Button
      if filterSize != .all || filterLength != .all || filterResolution != .all
        || filterFileType != .all
      {
        Button("Clear") {
          filterSize = .all
          filterLength = .all
          filterResolution = .all
          filterFileType = .all
        }
        .buttonStyle(.bordered)
        .font(.caption)
      }
    }
  }

  // Add this helper to ContentView for parsing duration string (e.g., "3:15") to seconds
  static func durationInSeconds(from durationString: String) -> Double? {
    let parts = durationString.split(separator: ":").map { Double($0) ?? 0 }
    guard parts.count == 2 else { return nil }
    return parts[0] * 60 + parts[1]
  }
}

// MARK: — Video Thumbnail View
struct VideoThumbnailView: View {
  let url: URL
  @State private var thumbnail: Image? = nil
  @State private var isLoading = true

  var body: some View {
    ZStack {
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
          .cornerRadius(8)
      } else if isLoading {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle())
      } else {
        Color.black
          .cornerRadius(8)
      }
    }
    .task {
      await loadThumbnail()
    }
  }

  private func loadThumbnail() async {
    if let cached = ContentView.thumbnailCache[url] {
      thumbnail = cached
      isLoading = false
      return
    }

    do {
      let asset = AVURLAsset(url: url)
      let duration = asset.duration.seconds
      let time = max(duration * 0.02, 0.1)  // Ensure we don't try to get frame at 0
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 600, height: 338)  // Reduced size for better performance
      generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
      generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
      let cmTime = CMTime(seconds: time, preferredTimescale: 600)
      let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
      let image = Image(decorative: cgImage, scale: 1.0)
      await MainActor.run {
        ContentView.thumbnailCache[url] = image
        thumbnail = image
        isLoading = false
      }
    } catch {
      print("Error loading thumbnail for \(url.lastPathComponent): \(error.localizedDescription)")
      await MainActor.run {
        isLoading = false
      }
    }
  }
}

// MARK: — Helper View: Looping Preview for Each Video

struct LoopingPreviewView: View {
  let assetURL: URL
  let clipLength: Int
  let isMuted: Bool

  var body: some View {
    VideoPreviewView(url: assetURL, isMuted: isMuted)
      .frame(width: 120, height: 80)
      .cornerRadius(6)
  }
}

struct VideoPreviewView: View {
  let url: URL
  let isMuted: Bool
  @State private var player: AVPlayer? = nil

  var body: some View {
    if let player = player {
      CustomVideoPlayerView(player: player)
        .frame(width: 120, height: 80)
        .cornerRadius(6)
    } else {
      Color.black
        .task {
          await setupPlayerAsync()
        }
    }
  }

  private func setupPlayerAsync() async {
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let newPlayer = AVPlayer(playerItem: item)
    newPlayer.isMuted = isMuted
    newPlayer.play()
    await MainActor.run {
      player = newPlayer
    }
  }
}

// MARK: — Helper View: Side-by-Side Clip Loop

struct SideBySideClipView: View {
  let assetURL: URL
  let startTime: CMTime
  let clipLength: Int
  let isMuted: Bool
  @State private var player: AVPlayer? = nil
  @State private var loopObserver: Any? = nil

  var body: some View {
    if let player = player {
      VideoPlayerView(player: player)
        .onAppear {
          startLoop()
        }
        .onDisappear {
          stopLoop()
        }
    } else {
      Color.black
        .task {
          await setupPlayerAsync()
        }
    }
  }

  private func setupPlayerAsync() async {
    do {
      let asset = AVURLAsset(url: assetURL)

      // Load asset asynchronously
      let (_, _) = try await asset.load(.tracks, .duration)

      let item = AVPlayerItem(asset: asset)
      let newPlayer = AVPlayer(playerItem: item)
      newPlayer.isMuted = isMuted
      newPlayer.volume = 0

      await MainActor.run {
        player = newPlayer
      }
    } catch {
      print("Error setting up side-by-side player: \(error.localizedDescription)")
    }
  }

  private func startLoop() {
    guard let player = player else { return }
    player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
      player.play()
    }
    let interval = CMTime(seconds: Double(clipLength), preferredTimescale: 600)
    loopObserver = player.addBoundaryTimeObserver(
      forTimes: [NSValue(time: startTime + interval)], queue: .main
    ) {
      player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
        player.play()
      }
    }
  }

  private func stopLoop() {
    if let obs = loopObserver, let player = player {
      player.removeTimeObserver(obs)
      loopObserver = nil
    }
    player?.pause()
    player = nil
  }
}

struct VideoPlayerView: View {
  let player: AVPlayer
  @State private var isReady = false
  @State private var error: Error? = nil
  @State private var isPlaying = false
  @State private var playerItemStatus: AVPlayerItem.Status = .unknown
  @State private var cancellables = Set<AnyCancellable>()

  var body: some View {
    ZStack {
      CustomVideoPlayerView(player: player)
        .onAppear {
          preparePlayer()
        }
        .onDisappear {
          cleanup()
        }

      if !isReady {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle())
          .scaleEffect(1.5)
      }

      if let error = error {
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 24))
          Text(error.localizedDescription)
            .font(.caption)
            .multilineTextAlignment(.center)
        }
        .foregroundColor(.red)
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
      }
    }
  }

  private func preparePlayer() {
    guard let currentItem = player.currentItem else {
      error = NSError(
        domain: "VideoPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No player item"])
      return
    }

    // Reset state
    isReady = false
    error = nil
    isPlaying = false
    playerItemStatus = .unknown

    // Observe player item status
    currentItem.publisher(for: \.status)
      .receive(on: DispatchQueue.main)
      .sink { status in
        playerItemStatus = status
        switch status {
        case .readyToPlay:
          isReady = true
          error = nil
          // Only start playback if the view is still visible
          if !cancellables.isEmpty {
            player.play()
            isPlaying = true
          }
        case .failed:
          error =
            currentItem.error
            ?? NSError(
              domain: "VideoPlayer", code: -2,
              userInfo: [NSLocalizedDescriptionKey: "Failed to load video"])
          isReady = false
        case .unknown:
          isReady = false
        @unknown default:
          isReady = false
        }
      }
      .store(in: &cancellables)

    // Observe playback failures
    NotificationCenter.default.publisher(
      for: .AVPlayerItemFailedToPlayToEndTime, object: currentItem
    )
    .receive(on: DispatchQueue.main)
    .sink { notification in
      if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
        self.error = error
        isReady = false
      }
    }
    .store(in: &cancellables)

    // Observe item end
    NotificationCenter.default.publisher(
      for: .AVPlayerItemDidPlayToEndTime, object: currentItem
    )
    .receive(on: DispatchQueue.main)
    .sink { _ in
      if !cancellables.isEmpty {
        player.seek(to: .zero)
        player.play()
      }
    }
    .store(in: &cancellables)
  }

  private func cleanup() {
    // First pause playback
    player.pause()

    // Then remove observers
    cancellables.removeAll()

    // Only reset player state if we still have a valid item
    if player.currentItem != nil {
      player.seek(to: .zero)
      player.rate = 0
    }
  }
}

struct PreviewCard: View {
  let url: URL
  let clipLength: Int
  let isMuted: Bool

  @State private var isHovered = false
  @State private var thumbnail: Image? = nil
  @State private var player: AVPlayer? = nil
  @State private var loadError: Bool = false
  @State private var isPlaying = false
  @State private var isPlayerReady = false

  static var thumbnailCache: [URL: Image] = [:]
  static var thumbnailLoadingQueue = DispatchQueue(
    label: "com.videoculler.thumbnail", qos: .userInitiated)
  static let thumbnailTimeout: TimeInterval = 2.0  // Reduced timeout

  static func loadThumbnail(for url: URL) async -> (Image?, Bool) {
    if let cached = thumbnailCache[url] {
      return (cached, false)
    }

    do {
      let asset = AVURLAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 1200, height: 675)  // Much higher resolution for crisp thumbnails
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero

      // Reduced delay for faster thumbnail loading
      try await Task.sleep(nanoseconds: 25_000_000)  // 25ms delay

      // Get the duration and use 2% offset
      let duration = try await asset.load(.duration)
      let time = max(duration.seconds * 0.02, 0.0)
      let cmTime = CMTime(seconds: time, preferredTimescale: 600)
      let cgImage = try await generator.image(at: cmTime).image
      let image = Image(cgImage, scale: 1.0, label: Text(url.lastPathComponent))

      await MainActor.run {
        thumbnailCache[url] = image
      }
      return (image, false)
    } catch {
      print("Error loading thumbnail for \(url.lastPathComponent): \(error.localizedDescription)")
      return (nil, true)
    }
  }

  var body: some View {
    ZStack {
      if isHovered && isPlaying && isPlayerReady {
        if let player = player {
          VideoPlayerView(player: player)
        } else {
          Color.black
        }
      } else if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else if loadError {
        VStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 20))
          Text("Preview Unavailable")
            .font(.caption)
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
      } else {
        Color.black
      }
    }
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        setupPlayer()
      } else {
        cleanupPlayer()
      }
    }
    .task {
      let (image, error) = await Self.loadThumbnail(for: url)
      await MainActor.run {
        thumbnail = image
        loadError = error
      }
    }
    .onDisappear {
      cleanupPlayer()
    }
  }

  private func setupPlayer() {
    if player == nil {
      Task {
        do {
          // Reduced timeout for faster hover response
          try await withTimeout(2.0) {
            let asset = AVURLAsset(url: url)

            // Load only duration, not tracks (faster)
            let _ = try await asset.load(.duration)

            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = isMuted
            newPlayer.volume = 0
            newPlayer.actionAtItemEnd = .pause

            await MainActor.run {
              player = newPlayer
              isPlayerReady = true

              // Start playback immediately if still hovered
              if isHovered {
                player?.play()
                isPlaying = true
              }
            }
          }
        } catch {
          print(
            "Error setting up player for \(url.lastPathComponent): \(error.localizedDescription)")
          await MainActor.run {
            loadError = true
          }
        }
      }
    }
  }

  private func cleanupPlayer() {
    guard let player = player else { return }
    player.pause()
    player.seek(to: .zero)
    player.rate = 0
    self.player = nil
    isPlaying = false
    isPlayerReady = false
  }
}

struct FolderViewPreviewCard: View {
  let url: URL
  let clipLength: Int
  let isMuted: Bool
  @Binding var isMarkedForDeletion: Bool

  @State private var isHovered = false
  @State private var thumbnail: Image? = nil
  @State private var player: AVPlayer? = nil
  @State private var loadError: Bool = false
  @State private var isPlaying = false
  @State private var isPlayerReady = false

  var body: some View {
    ZStack {
      if isHovered && isPlaying && isPlayerReady {
        if let player = player {
          VideoPlayerView(player: player)
        } else {
          Color.black
        }
      } else if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else if loadError {
        VStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 20))
          Text("Preview Unavailable")
            .font(.caption)
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
      } else {
        Color.black
      }

      if isMarkedForDeletion {
        Color.red.opacity(0.3)
      }
    }
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        setupPlayer()
      } else {
        cleanupPlayer()
      }
    }
    .onTapGesture {
      isMarkedForDeletion.toggle()
    }
    .onTapGesture(count: 2) {
      NSWorkspace.shared.selectFile(
        url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
    .task {
      let (image, error) = await PreviewCard.loadThumbnail(for: url)
      await MainActor.run {
        thumbnail = image
        loadError = error
      }
    }
    .onDisappear {
      cleanupPlayer()
    }
  }

  private func setupPlayer() {
    if player == nil {
      Task {
        do {
          // Reduced timeout for faster hover response
          try await withTimeout(2.0) {
            let asset = AVURLAsset(url: url)

            // Load only duration, not tracks (faster)
            let _ = try await asset.load(.duration)

            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = isMuted
            newPlayer.volume = 0
            newPlayer.actionAtItemEnd = .pause

            await MainActor.run {
              player = newPlayer
              isPlayerReady = true

              // Start playback immediately if still hovered
              if isHovered {
                player?.play()
                isPlaying = true
              }
            }
          }
        } catch {
          print(
            "Error setting up player for \(url.lastPathComponent): \(error.localizedDescription)")
          await MainActor.run {
            loadError = true
          }
        }
      }
    }
  }

  private func cleanupPlayer() {
    guard let player = player else { return }
    player.pause()
    player.seek(to: .zero)
    player.rate = 0
    self.player = nil
    isPlaying = false
    isPlayerReady = false
  }
}

// MARK: — Video Clip Preview
struct VideoClipPreview: View {
  let url: URL
  let startTime: Double
  let length: Double
  let isMuted: Bool
  @State private var player: AVPlayer? = nil
  var body: some View {
    Group {
      if let player = player {
        NoControlsPlayerView(player: player)
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

// MARK: — Hover Preview Card
struct HoverPreviewCard: View {
  let url: URL
  let thumbnail: Image?
  let isMuted: Bool
  var startTime: Double = 0
  var forcePlay: Bool = false
  var playbackType: PlaybackType
  var speedOption: SpeedOption
  @State private var player: AVPlayer? = nil
  @State private var asset: AVURLAsset? = nil
  @State private var duration: Double = 0
  @State private var periodicTimeObserver: Any? = nil
  @State private var rateObserver: NSObjectProtocol? = nil
  @State private var playbackEndObserver: NSObjectProtocol? = nil
  @State private var pendingSpeedPlayback: Bool = false
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
        NoControlsPlayerView(player: player)
          .onAppear {
            if isAssetReady {
              startSpeedPlayback()
            }
          }
          .onDisappear {
            stopPlayback()
          }
      } else if forcePlay && playbackType == .clips {
        if let player = player {
          NoControlsPlayerView(player: player)
            .onAppear {
              player.seek(
                to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero,
                toleranceAfter: .zero)
              player.play()
            }
            .onDisappear {
              stopPlayback()
            }
        } else {
          Color.clear
            .onAppear {
              createPlayerForClips()
            }
        }
      }
    }
    .clipped()
    .onAppear {
      // Pre-create asset for faster hover response
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
      } else if !newForcePlay {
        stopPlayback()
      }
    }
  }

  private func preCreateAsset() {
    // Pre-create asset but don't load heavy properties yet
    asset = AVURLAsset(url: url)

    // Load duration in background for speed mode
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

    // Set up observers
    let interval = CMTime(seconds: 0.2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    periodicTimeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      _ in
    }

    rateObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemTimeJumped,
      object: playerItem,
      queue: .main
    ) { _ in
      newPlayer.rate = Float(speedOption.rawValue)
    }

    startSpeedPlayback()
  }

  private func startSpeedPlayback() {
    guard let player = player, duration > 0 else { return }

    let startTime = duration * 0.02
    player.seek(
      to: CMTime(seconds: startTime, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { _ in
      player.rate = Float(speedOption.rawValue)
      player.play()
    }

    // Set up end-of-video looping
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      player.seek(
        to: CMTime(seconds: startTime, preferredTimescale: 600),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      ) { _ in
        player.rate = Float(speedOption.rawValue)
        player.play()
      }
    }
  }

  private func updateSpeedPlayback() {
    guard let player = player else { return }
    // Just update the rate, don't recreate everything
    player.rate = Float(speedOption.rawValue)
  }

  private func stopPlayback() {
    player?.pause()
    player?.rate = 0

    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }
    if let observer = periodicTimeObserver {
      player?.removeTimeObserver(observer)
      periodicTimeObserver = nil
    }
    if let observer = rateObserver {
      NotificationCenter.default.removeObserver(observer)
      rateObserver = nil
    }

    // Keep the asset for reuse, just clear the player
    player = nil
    pendingSpeedPlayback = false
  }
}

// MARK: — Folder Hover Loop Preview
struct FolderHoverLoopPreview: View {
  let url: URL
  let isMuted: Bool
  let numberOfClips: Int
  let clipLength: Int
  let playbackType: PlaybackType
  let speedOption: SpeedOption
  @State private var isHovered = false
  @State private var player: AVPlayer? = nil
  @State private var asset: AVURLAsset? = nil
  @State private var currentClip: Int = 0
  @State private var timer: Timer? = nil
  @State private var startTimes: [Double] = []
  @State private var duration: Double = 0
  @State private var boundaryObserver: Any? = nil
  @State private var fadeOpacity: Double = 0.0
  @State private var isTransitioning: Bool = false
  @State private var isUserControlling: Bool = false
  @State private var lastSeekTime: Double = 0
  @State private var thumbnail: Image? = nil
  @State private var playbackEndObserver: NSObjectProtocol? = nil
  @State private var periodicTimeObserver: Any? = nil
  @State private var isAssetReady: Bool = false

  var body: some View {
    ZStack {
      // Always show the thumbnail as background
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
          .cornerRadius(8)
      } else {
        Color.black
          .cornerRadius(8)
      }

      // Overlay the video player when hovered
      if isHovered, let player = player {
        NoControlsPlayerView(player: player)
          .cornerRadius(8)
          .opacity(fadeOpacity)
          .onAppear {
            print("FolderHoverLoopPreview: View appeared for \(url.lastPathComponent)")
            withAnimation(.easeIn(duration: 0.2)) {
              fadeOpacity = 1.0
            }
            if playbackType == .clips {
              print("FolderHoverLoopPreview: Starting clip looping for \(url.lastPathComponent)")
              startLoopingClips()
            } else {
              print("FolderHoverLoopPreview: Starting speed playback for \(url.lastPathComponent)")
              startSpeedPlayback()
            }
          }
          .onDisappear {
            print("FolderHoverLoopPreview: View disappeared for \(url.lastPathComponent)")
            withAnimation(.easeOut(duration: 0.2)) {
              fadeOpacity = 0.0
            }
            stopPlayback()
          }
      }
    }
    .onHover { hovering in
      print(
        "FolderHoverLoopPreview: Hover state changed to \(hovering) for \(url.lastPathComponent)")
      isHovered = hovering
      if hovering {
        if player == nil && isAssetReady {
          print("FolderHoverLoopPreview: Creating player for \(url.lastPathComponent)")
          createPlayer()
        } else if player != nil {
          if playbackType == .clips {
            print("FolderHoverLoopPreview: Restarting clip looping for \(url.lastPathComponent)")
            startLoopingClips()
          } else {
            print("FolderHoverLoopPreview: Restarting speed playback for \(url.lastPathComponent)")
            startSpeedPlayback()
          }
        }
      } else {
        print("FolderHoverLoopPreview: Stopping playback for \(url.lastPathComponent)")
        stopPlayback()
      }
    }
    .onAppear {
      // Pre-create asset for faster hover response
      if asset == nil {
        preCreateAsset()
      }
    }
    .task {
      // Load thumbnail
      if let cached = ContentView.thumbnailCache[url] {
        thumbnail = cached
      } else {
        do {
          let asset = AVURLAsset(url: url)
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          generator.maximumSize = CGSize(width: 1200, height: 675)  // Much higher resolution for crisp thumbnails
          generator.requestedTimeToleranceBefore = .zero
          generator.requestedTimeToleranceAfter = .zero
          // Use the same 2% offset as the video preview
          let cmTime = CMTime(seconds: asset.duration.seconds * 0.02, preferredTimescale: 600)
          let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
          let image = Image(decorative: cgImage, scale: 1.0)
          ContentView.thumbnailCache[url] = image
          thumbnail = image
        } catch {
          print(
            "Error loading thumbnail for \(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
    }
    .clipped()
    .cornerRadius(8)
  }

  private func preCreateAsset() {
    print("FolderHoverLoopPreview: Pre-creating asset for \(url.lastPathComponent)")
    asset = AVURLAsset(url: url)

    // Load duration in background
    Task {
      if let asset = asset {
        let loadedDuration = try? await asset.load(.duration)
        await MainActor.run {
          self.duration = loadedDuration?.seconds ?? 0
          if playbackType == .clips && duration > 0 {
            startTimes = computeStartTimes(duration: duration, count: numberOfClips)
            print(
              "FolderHoverLoopPreview: Generated clip times: \(startTimes) for \(url.lastPathComponent)"
            )
          }
          self.isAssetReady = true
          print("FolderHoverLoopPreview: Asset ready for \(url.lastPathComponent)")

          // If we're hovered and waiting, create player now
          if isHovered && player == nil {
            createPlayer()
          }
        }
      }
    }
  }

  private func createPlayer() {
    guard let asset = asset, isAssetReady else { return }
    print("FolderHoverLoopPreview: Creating player for \(url.lastPathComponent)")

    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    // Add periodic time observer (less frequent for better performance)
    let interval = CMTime(seconds: 0.2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    periodicTimeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      time in
      // Removed debug print for performance
    }

    // Start playback based on type
    if playbackType == .clips {
      startLoopingClips()
    } else {
      startSpeedPlayback()
    }
  }

  private func computeStartTimes(duration: Double, count: Int) -> [Double] {
    guard duration > 0, count > 0 else { return [] }
    let start = duration * 0.02  // Start at 2% of video
    let interval = (duration * 0.96) / Double(count)  // Distribute remaining 96% evenly
    return (0..<count).map { start + Double($0) * interval }
  }

  private func startSpeedPlayback() {
    guard let player = player else {
      print(
        "FolderHoverLoopPreview: Cannot start playback - player is nil for \(url.lastPathComponent)"
      )
      return
    }

    print(
      "FolderHoverLoopPreview: Starting speed playback at \(speedOption.rawValue)x for \(url.lastPathComponent)"
    )
    player.rate = Float(speedOption.rawValue)
    player.seek(to: CMTime(seconds: duration * 0.02, preferredTimescale: 600))
    player.play()

    // Add playback end observer
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      print("FolderHoverLoopPreview: Playback ended for \(url.lastPathComponent)")
      player.seek(to: CMTime(seconds: duration * 0.02, preferredTimescale: 600))
      player.play()
    }
  }

  private func startLoopingClips() {
    guard let player = player else {
      print(
        "FolderHoverLoopPreview: Cannot start clip looping - player is nil for \(url.lastPathComponent)"
      )
      return
    }

    print("FolderHoverLoopPreview: Starting clip looping for \(url.lastPathComponent)")
    currentClip = 0
    playCurrentClip()
  }

  private func playCurrentClip() {
    guard let player = player, !startTimes.isEmpty else {
      print(
        "FolderHoverLoopPreview: Cannot play clip - player is nil or no start times for \(url.lastPathComponent)"
      )
      return
    }

    let startTime = startTimes[currentClip]
    print(
      "FolderHoverLoopPreview: Playing clip \(currentClip + 1)/\(startTimes.count) at time \(startTime) for \(url.lastPathComponent)"
    )

    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
    player.rate = 1.0
    player.play()

    // Schedule next clip
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Double(clipLength), repeats: false) { _ in
      self.currentClip = (self.currentClip + 1) % self.startTimes.count
      print(
        "FolderHoverLoopPreview: Moving to next clip \(self.currentClip + 1)/\(self.startTimes.count) for \(url.lastPathComponent)"
      )
      self.playCurrentClip()
    }
  }

  private func stopPlayback() {
    print("FolderHoverLoopPreview: Stopping playback for \(url.lastPathComponent)")
    player?.pause()
    player?.rate = 0
    timer?.invalidate()
    timer = nil

    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }

    if let observer = periodicTimeObserver {
      player?.removeTimeObserver(observer)
      periodicTimeObserver = nil
    }
  }
}

struct NoControlsPlayerView: NSViewRepresentable {
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

// MARK: — Speed Mode Views

// MARK: — Single Speed Player Fill
struct SingleSpeedPlayerFill: View {
  let url: URL
  @Binding var speedOption: SpeedOption
  @Binding var isMuted: Bool
  @State private var player: AVPlayer? = nil
  @State private var duration: Double = 0
  @State private var didAppear: Bool = false
  @State private var showFallback: Bool = false
  @State private var errorMessage: String? = nil
  @State private var playbackEndObserver: NSObjectProtocol? = nil
  @State private var periodicTimeObserver: Any? = nil
  @State private var rateObserver: Any? = nil

  var body: some View {
    Group {
      if showFallback || errorMessage != nil {
        VideoFallbackView(
          url: url,
          errorMessage: errorMessage ?? "Unknown error"
        )
      } else if let player = player {
        CustomVideoPlayerWithControls(
          player: player,
          mode: .speed,
          onSpeedChange: { newSpeed in
            speedOption = newSpeed
            updatePlaybackSpeed()
          },
          currentSpeed: speedOption,
          globalIsMuted: $isMuted
        )
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
        .onAppear {
          if !didAppear {
            print("SingleSpeedPlayerFill: Starting playback with speed \(speedOption.rawValue)")
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
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .cornerRadius(12)
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanup()
    }
    .onChange(of: speedOption) { _ in
      updatePlaybackSpeed()
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

        // Add periodic time observer for debugging
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        periodicTimeObserver = newPlayer.addPeriodicTimeObserver(
          forInterval: interval, queue: .main
        ) { time in
          print(
            "SingleSpeedPlayerFill: Current rate: \(newPlayer.rate), Expected rate: \(speedOption.rawValue)"
          )
        }

        // Add rate observer (but don't interfere with intentional pausing)
        rateObserver = newPlayer.addPeriodicTimeObserver(
          forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
          queue: .main
        ) { _ in
          // Only restore rate if it's not intentionally paused (rate = 0)
          // and if it's not the expected speed rate
          if newPlayer.rate != 0 && newPlayer.rate != Float(speedOption.rawValue) {
            print(
              "SingleSpeedPlayerFill: Rate mismatch detected, forcing rate to \(speedOption.rawValue)"
            )
            newPlayer.rate = Float(speedOption.rawValue)
          }
        }

        // Observe player status
        NotificationCenter.default.addObserver(
          forName: .AVPlayerItemFailedToPlayToEndTime,
          object: item,
          queue: .main
        ) { note in
          errorMessage = "Failed to play video."
          showFallback = true
        }
        NotificationCenter.default.addObserver(
          forName: .AVPlayerItemNewErrorLogEntry,
          object: item,
          queue: .main
        ) { note in
          errorMessage = "Playback error: \(String(describing: item.error?.localizedDescription))"
          showFallback = true
        }

        // Observe rate changes (but don't interfere with intentional pausing)
        NotificationCenter.default.addObserver(
          forName: .AVPlayerItemTimeJumped,
          object: item,
          queue: .main
        ) { _ in
          // Only restore rate if not intentionally paused
          if newPlayer.rate != 0 {
            print("SingleSpeedPlayerFill: Time jumped, ensuring rate is \(speedOption.rawValue)")
            newPlayer.rate = Float(speedOption.rawValue)
          }
        }

        startSpeedPlayback()
      }
    }
  }

  private func startSpeedPlayback() {
    guard let player = player else { return }
    // Start at 2% of the video duration
    let startTime = duration * 0.02
    print(
      "SingleSpeedPlayerFill: Setting up playback at time \(startTime) with speed \(speedOption.rawValue)"
    )

    // Set rate before seeking
    player.rate = Float(speedOption.rawValue)
    print("SingleSpeedPlayerFill: Initial rate set to \(player.rate)")

    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { _ in
      // Set rate again after seeking
      player.rate = Float(speedOption.rawValue)
      print("SingleSpeedPlayerFill: Rate after seek: \(player.rate)")
      player.play()
    }

    // Add observer for playback end
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      // When video ends, seek back to 2% and continue playing
      print(
        "SingleSpeedPlayerFill: Video ended, restarting at \(startTime) with speed \(speedOption.rawValue)"
      )
      player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { _ in
        player.rate = Float(speedOption.rawValue)
        print("SingleSpeedPlayerFill: Rate after end seek: \(player.rate)")
        player.play()
      }
    }
  }

  private func stopPlayback() {
    if let player = player {
      player.pause()
      player.rate = 0
    }
    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }
    if let observer = periodicTimeObserver {
      player?.removeTimeObserver(observer)
      periodicTimeObserver = nil
    }
    if let observer = rateObserver {
      player?.removeTimeObserver(observer)
      rateObserver = nil
    }
  }

  private func updatePlaybackSpeed() {
    guard let player = player else { return }
    print("SingleSpeedPlayerFill: Updating speed to \(speedOption.rawValue)")
    player.rate = Float(speedOption.rawValue)
  }

  private func cleanup() {
    stopPlayback()
    player = nil
    didAppear = false
  }
}

// MARK: — Speed Clip Preview
struct SpeedClipPreview: View {
  let url: URL
  let speedOption: SpeedOption
  let isMuted: Bool
  @State private var player: AVPlayer? = nil
  @State private var duration: Double = 0
  @State private var didAppear: Bool = false
  @State private var showFallback: Bool = false
  @State private var errorMessage: String? = nil
  @State private var playbackEndObserver: NSObjectProtocol? = nil
  @State private var periodicTimeObserver: Any? = nil
  @State private var rateObserver: Any? = nil

  var body: some View {
    Group {
      if showFallback || errorMessage != nil {
        VideoFallbackView(
          url: url,
          errorMessage: errorMessage ?? "Unknown error"
        )
      } else if let player = player {
        CustomVideoPlayerView(player: player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .cornerRadius(12)
          .onAppear {
            if !didAppear {
              print("SpeedClipPreview: Starting playback with speed \(speedOption.rawValue)")
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
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .cornerRadius(12)
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
    asset.loadValuesAsynchronously(forKeys: ["duration"]) {
      let d = asset.duration.seconds
      DispatchQueue.main.async {
        duration = d
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isMuted
        player = newPlayer

        // Add periodic time observer for debugging
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        periodicTimeObserver = newPlayer.addPeriodicTimeObserver(
          forInterval: interval, queue: .main
        ) { time in
          print(
            "SpeedClipPreview: Current rate: \(newPlayer.rate), Expected rate: \(speedOption.rawValue)"
          )
        }

        // Add rate observer (but don't interfere with intentional pausing)
        rateObserver = newPlayer.addPeriodicTimeObserver(
          forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
          queue: .main
        ) { _ in
          // Only restore rate if it's not intentionally paused (rate = 0)
          // and if it's not the expected speed rate
          if newPlayer.rate != 0 && newPlayer.rate != Float(speedOption.rawValue) {
            print(
              "SpeedClipPreview: Rate mismatch detected, forcing rate to \(speedOption.rawValue)")
            newPlayer.rate = Float(speedOption.rawValue)
          }
        }

        // Observe player status
        NotificationCenter.default.addObserver(
          forName: .AVPlayerItemFailedToPlayToEndTime,
          object: item,
          queue: .main
        ) { note in
          errorMessage = "Failed to play video."
          showFallback = true
        }
        NotificationCenter.default.addObserver(
          forName: .AVPlayerItemNewErrorLogEntry,
          object: item,
          queue: .main
        ) { note in
          errorMessage = "Playback error: \(String(describing: item.error?.localizedDescription))"
          showFallback = true
        }

        // Observe rate changes (but don't interfere with intentional pausing)
        NotificationCenter.default.addObserver(
          forName: .AVPlayerItemTimeJumped,
          object: item,
          queue: .main
        ) { _ in
          // Only restore rate if not intentionally paused
          if newPlayer.rate != 0 {
            print("SpeedClipPreview: Time jumped, ensuring rate is \(speedOption.rawValue)")
            newPlayer.rate = Float(speedOption.rawValue)
          }
        }

        startSpeedPlayback()
      }
    }
  }

  private func startSpeedPlayback() {
    guard let player = player else { return }
    // Start at 2% of the video duration
    let startTime = duration * 0.02
    print(
      "SpeedClipPreview: Setting up playback at time \(startTime) with speed \(speedOption.rawValue)"
    )

    // Set rate before seeking
    player.rate = Float(speedOption.rawValue)
    print("SpeedClipPreview: Initial rate set to \(player.rate)")

    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { _ in
      // Set rate again after seeking
      player.rate = Float(speedOption.rawValue)
      print("SpeedClipPreview: Rate after seek: \(player.rate)")
      player.play()
    }

    // Add observer for playback end
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      // When video ends, seek back to 2% and continue playing
      print(
        "SpeedClipPreview: Video ended, restarting at \(startTime) with speed \(speedOption.rawValue)"
      )
      player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600)) { _ in
        player.rate = Float(speedOption.rawValue)
        print("SpeedClipPreview: Rate after end seek: \(player.rate)")
        player.play()
      }
    }
  }

  private func stopPlayback() {
    if let player = player {
      player.pause()
      player.rate = 0
    }
    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }
    if let observer = periodicTimeObserver {
      player?.removeTimeObserver(observer)
      periodicTimeObserver = nil
    }
    if let observer = rateObserver {
      player?.removeTimeObserver(observer)
      rateObserver = nil
    }
  }

  private func cleanup() {
    stopPlayback()
    player = nil
    didAppear = false
  }
}

// MARK: — Speed Hover Preview Card
struct SpeedHoverPreviewCard: View {
  let url: URL
  let thumbnail: Image?
  let isMuted: Bool
  let speedOption: SpeedOption
  var forcePlay: Bool = false
  @State private var player: AVPlayer? = nil
  @State private var isPlayerReady: Bool = false
  @State private var playbackEndObserver: NSObjectProtocol? = nil
  @State private var duration: Double = 0

  var body: some View {
    ZStack {
      // Always show the static thumbnail as the background
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Color.black
      }
      // Overlay the video player if forcePlay is true and player is ready
      if forcePlay {
        if let player = player {
          NoControlsPlayerView(player: player)
            .onAppear {
              startSpeedPlayback()
            }
            .onDisappear {
              stopPlayback()
            }
        } else {
          Color.clear
            .onAppear {
              if player == nil {
                setupPlayer()
              }
            }
        }
      }
    }
    .clipped()
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let newPlayer = AVPlayer(playerItem: item)
    newPlayer.isMuted = isMuted

    // Load duration
    asset.loadValuesAsynchronously(forKeys: ["duration"]) {
      let d = asset.duration.seconds
      DispatchQueue.main.async {
        duration = d
        player = newPlayer
        isPlayerReady = true
        if forcePlay {
          startSpeedPlayback()
        }
      }
    }
  }

  private func startSpeedPlayback() {
    guard let player = player else { return }
    // Start at 2% of the video duration
    let startTime = duration * 0.02
    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
    player.rate = Float(speedOption.rawValue)
    player.play()

    // Add observer for playback end
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      // When video ends, seek back to 2% and continue playing
      player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
      player.rate = Float(speedOption.rawValue)
      player.play()
    }
  }

  private func stopPlayback() {
    if let player = player {
      player.pause()
      player.rate = 0
    }
    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }
  }
}

// MARK: — Folder Speed Preview
struct FolderSpeedPreview: View {
  let url: URL
  let isMuted: Bool
  let speedOption: SpeedOption
  @State private var isHovered = false
  @State private var player: AVPlayer? = nil
  @State private var asset: AVURLAsset? = nil
  @State private var duration: Double = 0
  @State private var fadeOpacity: Double = 0.0
  @State private var thumbnail: Image? = nil
  @State private var playbackEndObserver: NSObjectProtocol? = nil
  @State private var periodicTimeObserver: Any? = nil
  @State private var rateObserver: NSObjectProtocol? = nil
  @State private var pendingSpeedPlayback: Bool = false
  @State private var isAssetReady: Bool = false

  var body: some View {
    ZStack {
      if let thumbnail = thumbnail {
        thumbnail
          .resizable()
          .aspectRatio(contentMode: .fill)
          .cornerRadius(8)
      } else {
        Color.black
          .cornerRadius(8)
      }
      if isHovered, let player = player {
        NoControlsPlayerView(player: player)
          .cornerRadius(8)
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
      // Pre-create asset for faster hover response
      if asset == nil {
        preCreateAsset()
      }
    }
    .onChange(of: speedOption) { _ in
      if isHovered, let player = player {
        // Just update the rate, don't recreate everything
        updateSpeedPlayback()
      }
    }
    .task {
      if let cached = ContentView.thumbnailCache[url] {
        thumbnail = cached
      } else {
        do {
          let asset = AVURLAsset(url: url)
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          generator.maximumSize = CGSize(width: 600, height: 338)  // Reduced size for better performance
          generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
          generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
          let time = max(asset.duration.seconds * 0.02, 0.1)  // Ensure we don't try to get frame at 0
          let cmTime = CMTime(seconds: time, preferredTimescale: 600)
          let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
          let image = Image(decorative: cgImage, scale: 1.0)
          ContentView.thumbnailCache[url] = image
          thumbnail = image
        } catch {
          print(
            "Error loading thumbnail for \(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
    }
    .clipped()
    .cornerRadius(8)
  }

  private func preCreateAsset() {
    asset = AVURLAsset(url: url)

    // Load duration in background
    Task {
      if let asset = asset {
        let loadedDuration = try? await asset.load(.duration)
        await MainActor.run {
          self.duration = loadedDuration?.seconds ?? 0
          self.isAssetReady = true

          // If we're hovered and waiting, create player now
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

    // Set up observers with better performance
    let interval = CMTime(seconds: 0.2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    periodicTimeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      _ in
    }

    rateObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemTimeJumped,
      object: playerItem,
      queue: .main
    ) { _ in
      self.player?.rate = Float(self.speedOption.rawValue)
    }

    startSpeedPlayback()
  }

  private func startSpeedPlayback() {
    guard let player = player, duration > 0 else { return }

    let startTime = duration * 0.02
    player.seek(
      to: CMTime(seconds: startTime, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { _ in
      player.rate = Float(self.speedOption.rawValue)
      player.play()
    }

    // Set up end-of-video looping
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      player.seek(
        to: CMTime(seconds: startTime, preferredTimescale: 600),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      ) { _ in
        player.rate = Float(self.speedOption.rawValue)
        player.play()
      }
    }
  }

  private func updateSpeedPlayback() {
    guard let player = player else { return }
    // Just update the rate, don't recreate everything
    player.rate = Float(speedOption.rawValue)
  }

  private func stopPlayback() {
    player?.pause()
    player?.rate = 0
    if let observer = playbackEndObserver {
      NotificationCenter.default.removeObserver(observer)
      playbackEndObserver = nil
    }
    if let observer = periodicTimeObserver {
      player?.removeTimeObserver(observer)
      periodicTimeObserver = nil
    }
    if let observer = rateObserver {
      NotificationCenter.default.removeObserver(observer)
      rateObserver = nil
    }
    pendingSpeedPlayback = false
  }
}
