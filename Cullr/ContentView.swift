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
  case x16 = 16.0

  var id: Double { self.rawValue }
  var displayName: String { "x\(Int(self.rawValue))" }
}

enum SortOption: String, CaseIterable, Identifiable {
  case name = "Name"
  case dateAdded = "Date Added"
  case dateModified = "Date Modified"
  case size = "Size"

  var id: String { self.rawValue }
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

// MARK: — Key Event Handler for Global Spacebar
struct KeyEventHandlingView: NSViewRepresentable {
  var onSpace: () -> Void
  func makeNSView(context: Context) -> NSView {
    let view = KeyCatcherView()
    view.onSpace = onSpace
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
  class KeyCatcherView: NSView {
    var onSpace: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
      if event.keyCode == 49 {  // Spacebar
        onSpace?()
      } else {
        super.keyDown(with: event)
      }
    }
    override func viewDidMoveToWindow() {
      window?.makeFirstResponder(self)
    }
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
        }
      // Key event handler for global spacebar
      KeyEventHandlingView {
        if !hotkeyFieldFocused {
          handleGlobalSpacebar()
        }
      }
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)

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
    }
    .frame(minWidth: 1200, minHeight: 800)
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
            await initializeForCurrentMode()
            if let folder = folderURL {
              loadVideosAndThumbnails(from: folder)
            }
          }
        }
        .buttonStyle(.borderedProminent)
      }

      Spacer()

      Picker("Mode:", selection: $playbackMode) {
        ForEach(
          PlaybackMode.allCases.filter { mode in
            if playbackType == .speed {
              return mode != .sideBySide
            }
            return true
          }
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
      }
      return sortAscending ? result : !result
    }
  }

  // MARK: — Folder View
  private func folderView() -> some View {
    ZStack {
      VStack(spacing: 0) {
        if folderURL != nil && (playbackMode == .folderView || playbackMode == .batchList) {
          HStack {
            HStack(spacing: 4) {
              Picker("Sort by:", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                  Text(option.rawValue).tag(option)
                }
              }
              .frame(width: 120)

              Button(action: { sortAscending.toggle() }) {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
              }
              .buttonStyle(.plain)
            }
            Spacer()
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
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
            ForEach(videoURLs, id: \.self) { url in
              VStack(spacing: 4) {
                if playbackType == .speed {
                  FolderSpeedPreview(
                    url: url,
                    isMuted: isMuted,
                    speedOption: speedOption
                  )
                  .frame(width: 220, height: 124)
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
                  .frame(width: 220, height: 124)
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
                  }
                  .onKeyPress(.space) {
                    if selectedURLs.contains(url) {
                      NSWorkspace.shared.open(url)
                      return .handled
                    }
                    return .ignored
                  }
                }
                Text(url.lastPathComponent)
                  .font(.caption)
                  .lineLimit(2)
                  .truncationMode(.middle)
                  .frame(width: 220, alignment: .leading)
                if let info = fileInfo[url] {
                  Text("\(info.size) • \(info.duration)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 220, alignment: .leading)
                }
              }
            }
          }
          .padding(8)
        }
        Spacer()
        HStack {
          Text("\(selectedURLs.count) files selected")
            .foregroundColor(.secondary)
          Spacer()
          Button("Delete Selected Files") {
            Task {
              await processSelectedFiles(selected: selectedURLs)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(selectedURLs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
    guard currentIndex < videoURLs.count else { return }

    let url = videoURLs[currentIndex]
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)

    await MainActor.run {
      player = AVPlayer(playerItem: item)
      player?.isMuted = isMuted
      if playbackMode == .single {
        player?.play()
      }
    }
  }

  private func stopPlayback() {
    player?.pause()
    player = nil
  }

  // MARK: — Process Selected Files
  private func processSelectedFiles(selected: Set<URL>) async {
    guard let folder = folderURL, folderAccessing else { return }
    for url in selected {
      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      } catch {
        try? FileManager.default.removeItem(at: url)
      }
    }
    loadVideos(from: folder)
    selectedURLs.removeAll()
  }

  // MARK: — Folder Selection
  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose a folder containing video files"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.folder]
    panel.begin { response in
      if response == .OK, let url = panel.url {
        relinquishFolderAccess()
        folderURL = url
        isPrepared = false
        playbackMode = .folderView  // Reset to folder view mode

        if url.startAccessingSecurityScopedResource() {
          folderAccessing = true
          loadVideosAndThumbnails(from: url)
        }
        if let window = NSApplication.shared.windows.first {
          window.title = url.lastPathComponent
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
      let allClipTimes: [(URL, [Double])] = videoURLs.map { url in
        if playbackType == .speed {
          // For speed mode, only generate one thumbnail at 2% offset
          return (url, [0.02])
        } else {
          // For clips mode, generate thumbnails for all clips
          let times = [0.02] + getClipTimes(for: url, count: numberOfClips)
          return (url, times)
        }
      }
      thumbnailsToLoad = allClipTimes.reduce(0) { $0 + $1.1.count }
      thumbnailsLoaded = 0
      for (url, times) in allClipTimes {
        for time in times {
          generateStaticThumbnail(for: url, at: time, countForLoading: true)
        }
      }

      // Ensure we're in folder view mode
      playbackMode = .folderView

    } catch {
      print("Error loading directory contents: \(error.localizedDescription)")
    }
  }

  // MARK: — Static Thumbnail Generation (Batch List, with loading count)
  private func generateStaticThumbnail(for url: URL, at time: Double, countForLoading: Bool = false)
  {
    DispatchQueue.global(qos: .userInitiated).async {
      let asset = AVAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 400, height: 225)

      // Use the provided time directly since we already set it to 0.02 for speed mode in loadVideosAndThumbnails
      let cmTime = CMTime(seconds: time, preferredTimescale: 600)

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
    guard currentIndex < videoURLs.count,
      let folder = folderURL,
      folderAccessing
    else { return }

    let url = videoURLs[currentIndex]
    do {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    } catch {
      try? FileManager.default.removeItem(at: url)
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
    batchSelection = Array(repeating: false, count: videoURLs.count)
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
        if playbackType == .speed {
          SingleSpeedPlayerFill(
            url: url,
            speedOption: speedOption,
            isMuted: isMuted
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .aspectRatio(16 / 9, contentMode: .fit)
          .id(url)  // Force view recreation when URL changes
        } else {
          SingleClipLoopingPlayerFill(
            url: url,
            numberOfClips: numberOfClips,
            clipLength: clipLength,
            isMuted: isMuted
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .aspectRatio(16 / 9, contentMode: .fit)
          .id(url)  // Force view recreation when URL changes
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
        .background(.ultraThinMaterial)
      }
    }
  }

  // MARK: — Single Clip Looping Player (Fill Layout)
  struct SingleClipLoopingPlayerFill: View {
    let url: URL
    let numberOfClips: Int
    let clipLength: Int
    let isMuted: Bool
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
      ZStack {
        if showFallback {
          VideoPlayer(player: player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cornerRadius(12)
        } else if let player = player, !startTimes.isEmpty {
          VideoPlayer(player: player)
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
        }
        if let errorMessage = errorMessage {
          VStack {
            Spacer()
            HStack {
              Spacer()
              VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                  .font(.system(size: 32))
                  .foregroundColor(.red)
                Text(errorMessage)
                  .foregroundColor(.red)
                  .font(.headline)
                  .multilineTextAlignment(.center)
              }
              .padding()
              .background(Color.black.opacity(0.8))
              .cornerRadius(12)
              Spacer()
            }
            Spacer()
          }
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
        let times = computeStartTimes(duration: d, count: numberOfClips)
        DispatchQueue.main.async {
          duration = d
          startTimes = times
          let item = AVPlayerItem(asset: asset)
          let newPlayer = AVPlayer(playerItem: item)
          newPlayer.isMuted = isMuted
          newPlayer.actionAtItemEnd = .none
          player = newPlayer

          // Add periodic time observer for debugging
          let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
          periodicTimeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
          ) { time in
          }

          // Observe player status
          NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
          ) { note in
            errorMessage = "Failed to play video."
            showFallback = true
          }
          NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main
          ) { note in
            errorMessage = "Playback error: \(String(describing: item.error?.localizedDescription))"
            showFallback = true
          }

          // Observe seeking (only for significant time jumps)
          NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: item, queue: .main
          ) { note in
            let currentTime = newPlayer.currentTime().seconds
            // Only consider it user interaction if:
            // 1. The time jump is significant (> 1 second)
            // 2. We're not in the initialization phase
            // 3. We're not currently seeking
            // 4. We're not already stopping
            // 5. The time jump wasn't caused by our own clip transition
            let isOurSeek = abs(currentTime - startTimes[currentClip]) < 0.1
            if abs(currentTime - lastSeekTime) > 1.0 && !isInitializing && !isSeeking && !isStopping
              && !isOurSeek
            {
              isStopping = true
              isUserControlling = true
              stopLoopingClips()
              isStopping = false
            }
            lastSeekTime = currentTime
          }

          startLoopingClips()
          // Mark initialization as complete after a short delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            isInitializing = false
          }
        }
      }
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
      if currentIndex < videoURLs.count {
        let url = videoURLs[currentIndex]
        GeometryReader { geometry in
          let columns = max(1, Int(geometry.size.width / 320))
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
                .cornerRadius(12)
              } else {
                // In clips mode, show multiple previews
                let times = getClipTimes(for: url, count: numberOfClips)
                ForEach(Array(times.enumerated()), id: \.offset) { (i, start) in
                  VideoClipPreview(
                    url: url, startTime: start, length: Double(clipLength), isMuted: isMuted
                  )
                  .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
            HStack {
              HStack(spacing: 4) {
                Picker("Sort by:", selection: $sortOption) {
                  ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                  }
                }
                .frame(width: 120)

                Button(action: { sortAscending.toggle() }) {
                  Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.plain)
              }
              Spacer()
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
              ForEach(videoURLs, id: \.self) { url in
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
              Text("\(batchSelection.filter { $0 }.count) files selected")
                .foregroundColor(.secondary)
              Spacer()
              Button("Delete Selected Files") {
                let selected = Set(zip(videoURLs, batchSelection).filter { $0.1 }.map { $0.0 })
                Task {
                  await processSelectedFiles(selected: selected)
                }
              }
              .buttonStyle(.borderedProminent)
              .disabled(!batchSelection.contains(true))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
              .frame(width: 120, height: 68)
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
            .frame(width: 120, height: 68)
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
        .frame(width: 220, alignment: .leading)
        Spacer()
      }
      .contentShape(Rectangle())
      .onHover { hovering in
        print("BatchListRowView onHover for \(url.lastPathComponent): \(hovering)")
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
            generator.maximumSize = CGSize(width: 400, height: 225)
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
      let time = max(duration * 0.02, 0.0)  // This matches the hover preview start time
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 400, height: 225)
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
      VideoPlayer(player: player)
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
      if #available(macOS 12.0, *) {
        VideoPlayer(player: player)
          .onAppear {
            preparePlayer()
          }
          .onDisappear {
            cleanup()
          }
      } else {
        // Fallback for older macOS versions
        Color.black
          .onAppear {
            preparePlayer()
          }
          .onDisappear {
            cleanup()
          }
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
  static let thumbnailTimeout: TimeInterval = 3.0  // 3 second timeout

  static func loadThumbnail(for url: URL) async -> (Image?, Bool) {
    if let cached = thumbnailCache[url] {
      return (cached, false)
    }

    do {
      let asset = AVURLAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 300, height: 300)

      // Add a small delay between thumbnail generations
      try await Task.sleep(nanoseconds: 50_000_000)  // 50ms delay

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
          // Add timeout to prevent hanging
          try await withTimeout(5.0) {
            let asset = AVURLAsset(url: url)

            // Load asset asynchronously
            let (_, _) = try await asset.load(.tracks, .duration)

            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = isMuted
            newPlayer.volume = 0
            newPlayer.actionAtItemEnd = .pause

            await MainActor.run {
              player = newPlayer
              isPlayerReady = true

              // Start playback after a short delay
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if isHovered {
                  player?.play()
                  isPlaying = true
                }
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
          // Add timeout to prevent hanging
          try await withTimeout(5.0) {
            let asset = AVURLAsset(url: url)

            // Load asset asynchronously
            let (_, _) = try await asset.load(.tracks, .duration)

            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = isMuted
            newPlayer.volume = 0
            newPlayer.actionAtItemEnd = .pause

            await MainActor.run {
              player = newPlayer
              isPlayerReady = true

              // Start playback after a short delay
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if isHovered {
                  player?.play()
                  isPlaying = true
                }
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
  @State private var duration: Double = 0
  @State private var periodicTimeObserver: Any? = nil
  @State private var rateObserver: NSObjectProtocol? = nil
  @State private var playbackEndObserver: NSObjectProtocol? = nil
  @State private var pendingSpeedPlayback: Bool = false

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
            // Always recreate the player on hover-in
            playerCleanup()
            setupPlayer()
          }
          .onDisappear {
            stopPlayback()
          }
      } else if forcePlay && playbackType == .clips {
        if let player = player {
          NoControlsPlayerView(player: player)
            .onAppear {
              player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
              player.play()
            }
            .onDisappear {
              stopPlayback()
            }
        } else {
          Color.clear
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
    .clipped()
    .onChange(of: speedOption) { _ in
      if forcePlay && playbackType == .speed {
        playerCleanup()
        setupPlayer()
      }
    }
    .onChange(of: forcePlay) { newForcePlay in
      if newForcePlay && playbackType == .speed {
        playerCleanup()
        setupPlayer()
      } else if !newForcePlay {
        stopPlayback()
      }
    }
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    let newPlayer = AVPlayer(playerItem: playerItem)
    newPlayer.isMuted = isMuted
    player = newPlayer
    let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
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
    Task {
      let loadedDuration = try? await asset.load(.duration)
      await MainActor.run {
        self.duration = loadedDuration?.seconds ?? 0
        if forcePlay {
          resetAndStartSpeedPlayback()
        } else if pendingSpeedPlayback {
          pendingSpeedPlayback = false
          resetAndStartSpeedPlayback()
        }
      }
    }
  }

  private func resetAndStartSpeedPlayback() {
    guard let player = player else { return }
    guard duration > 0 else {
      pendingSpeedPlayback = true
      return
    }
    player.pause()
    player.rate = 0
    let startTime = duration * 0.02
    player.seek(
      to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { _ in
      player.rate = Float(speedOption.rawValue)
      player.play()
    }
    if playbackEndObserver != nil {
      NotificationCenter.default.removeObserver(playbackEndObserver!)
      playbackEndObserver = nil
    }
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      player.seek(
        to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero,
        toleranceAfter: .zero
      ) { _ in
        player.rate = Float(speedOption.rawValue)
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
    if let observer = periodicTimeObserver {
      player?.removeTimeObserver(observer)
      periodicTimeObserver = nil
    }
    if let observer = rateObserver {
      NotificationCenter.default.removeObserver(observer)
      rateObserver = nil
    }
    pendingSpeedPlayback = false
    player = nil
  }

  private func playerCleanup() {
    stopPlayback()
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
        if player == nil {
          print("FolderHoverLoopPreview: Setting up new player for \(url.lastPathComponent)")
          setupPlayer()
        } else {
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
    .task {
      // Load thumbnail
      if let cached = ContentView.thumbnailCache[url] {
        thumbnail = cached
      } else {
        do {
          let asset = AVURLAsset(url: url)
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          generator.maximumSize = CGSize(width: 400, height: 225)
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

  private func setupPlayer() {
    print("FolderHoverLoopPreview: Setting up player for \(url.lastPathComponent)")
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    // Add periodic time observer
    let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    periodicTimeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      time in
      print("FolderHoverLoopPreview: Current time: \(time.seconds) for \(url.lastPathComponent)")
    }

    // Observe duration
    Task {
      let duration = try await asset.load(.duration)
      print(
        "FolderHoverLoopPreview: Video duration: \(duration.seconds) for \(url.lastPathComponent)")
      await MainActor.run {
        self.duration = duration.seconds
        if playbackType == .clips {
          startTimes = computeStartTimes(duration: duration.seconds, count: numberOfClips)
          print(
            "FolderHoverLoopPreview: Generated clip times: \(startTimes) for \(url.lastPathComponent)"
          )
        }
      }
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
    print("NoControlsPlayerView: Creating new player view")
    let view = NSView()
    let playerLayer = AVPlayerLayer(player: player)
    playerLayer.videoGravity = .resizeAspectFill
    playerLayer.frame = .zero
    view.layer = playerLayer
    view.wantsLayer = true
    playerLayer.needsDisplayOnBoundsChange = true

    // Add rate observer
    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      print("NoControlsPlayerView: Current rate: \(player.rate), Time: \(time.seconds)")
    }
    context.coordinator.rateObserver = observer

    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let playerLayer = nsView.layer as? AVPlayerLayer {
      playerLayer.player = player
      playerLayer.frame = nsView.bounds

      // Force rate update
      let currentRate = player.rate
      print("NoControlsPlayerView update: Current rate: \(currentRate)")
      if currentRate != 0.0 {
        player.rate = currentRate
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  class Coordinator {
    var rateObserver: Any?

    deinit {
      if let observer = rateObserver {
        NotificationCenter.default.removeObserver(observer)
      }
    }
  }
}

// MARK: — Speed Mode Views

// MARK: — Single Speed Player Fill
struct SingleSpeedPlayerFill: View {
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
    ZStack {
      if showFallback {
        VideoPlayer(player: player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .cornerRadius(12)
      } else if let player = player {
        VideoPlayer(player: player)
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
      }
      if let errorMessage = errorMessage {
        VStack {
          Spacer()
          HStack {
            Spacer()
            VStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.red)
              Text(errorMessage)
                .foregroundColor(.red)
                .font(.headline)
                .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)
            Spacer()
          }
          Spacer()
        }
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
            "SingleSpeedPlayerFill: Current rate: \(newPlayer.rate), Expected rate: \(speedOption.rawValue)"
          )
        }

        // Add rate observer
        rateObserver = newPlayer.addPeriodicTimeObserver(
          forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
          queue: .main
        ) { _ in
          if newPlayer.rate != Float(speedOption.rawValue) {
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

        // Observe rate changes
        NotificationCenter.default.addObserver(
          forName: .AVPlayerItemTimeJumped,
          object: item,
          queue: .main
        ) { _ in
          print("SingleSpeedPlayerFill: Time jumped, ensuring rate is \(speedOption.rawValue)")
          newPlayer.rate = Float(speedOption.rawValue)
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
    ZStack {
      if showFallback {
        VideoPlayer(player: player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .cornerRadius(12)
      } else if let player = player {
        VideoPlayer(player: player)
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
      }
      if let errorMessage = errorMessage {
        VStack {
          Spacer()
          HStack {
            Spacer()
            VStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.red)
              Text(errorMessage)
                .foregroundColor(.red)
                .font(.headline)
                .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)
            Spacer()
          }
          Spacer()
        }
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

        // Add rate observer
        rateObserver = newPlayer.addPeriodicTimeObserver(
          forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
          queue: .main
        ) { _ in
          if newPlayer.rate != Float(speedOption.rawValue) {
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

        // Observe rate changes
        NotificationCenter.default.addObserver(
          forName: .AVPlayerItemTimeJumped,
          object: item,
          queue: .main
        ) { _ in
          print("SpeedClipPreview: Time jumped, ensuring rate is \(speedOption.rawValue)")
          newPlayer.rate = Float(speedOption.rawValue)
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
  @State private var duration: Double = 0
  @State private var fadeOpacity: Double = 0.0
  @State private var thumbnail: Image? = nil
  @State private var playbackEndObserver: NSObjectProtocol? = nil
  @State private var periodicTimeObserver: Any? = nil
  @State private var rateObserver: NSObjectProtocol? = nil
  @State private var pendingSpeedPlayback: Bool = false

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
            resetAndStartSpeedPlayback()
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
        // Always recreate the player on hover-in
        player = nil
        setupPlayer()
      } else {
        stopPlayback()
      }
    }
    .onChange(of: speedOption) { _ in
      if isHovered, player != nil {
        resetAndStartSpeedPlayback()
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
          generator.maximumSize = CGSize(width: 400, height: 225)
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

  private func setupPlayer() {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted
    let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    periodicTimeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      _ in
    }
    rateObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemTimeJumped,
      object: playerItem,
      queue: .main
    ) { _ in
      player?.rate = Float(speedOption.rawValue)
    }
    Task {
      let loadedDuration = try await asset.load(.duration)
      await MainActor.run {
        self.duration = loadedDuration.seconds
        if isHovered {
          resetAndStartSpeedPlayback()
        } else if pendingSpeedPlayback {
          pendingSpeedPlayback = false
          resetAndStartSpeedPlayback()
        }
      }
    }
  }

  private func resetAndStartSpeedPlayback() {
    guard let player = player else { return }
    guard duration > 0 else {
      pendingSpeedPlayback = true
      return
    }
    // Always pause before seeking
    player.pause()
    player.rate = 0
    let startTime = duration * 0.02
    player.seek(
      to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { _ in
      player.rate = Float(speedOption.rawValue)
      player.play()
    }
    // Remove old observer if any
    if playbackEndObserver != nil {
      NotificationCenter.default.removeObserver(playbackEndObserver!)
      playbackEndObserver = nil
    }
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      player.seek(
        to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero,
        toleranceAfter: .zero
      ) { _ in
        player.rate = Float(speedOption.rawValue)
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
