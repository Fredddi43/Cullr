// AppState.swift
// Centralized application state management for optimal performance and modularity

import AVFoundation
import AppKit
import SwiftUI

// MARK: - File Loading Manager

@MainActor
class FileLoadingManager: ObservableObject {
  @Published var isLoading = false
  @Published var thumbnailsLoaded = 0
  @Published var thumbnailsToLoad = 0
  @Published var fileInfo: [URL: FileInfo] = [:]

  private let maxConcurrentTasks = 8  // Optimize for performance

  func loadVideosAndInfo(from folderURL: URL, sortOption: SortOption, sortAscending: Bool) async
    -> [URL]
  {
    do {
      let fileManager = FileManager.default
      let contents = try fileManager.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]
      )

      let videos = contents.filter { fileManager.isVideoFile($0) }

      // Optimized sorting with timeout
      let sortedVideos = try await withTimeout(10) {
        return videos.sorted { url1, url2 in
          switch sortOption {
          case .name:
            return sortAscending
              ? url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
                == .orderedAscending
              : url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
                == .orderedDescending
          case .dateModified:
            let date1 =
              (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?
              .contentModificationDate ?? Date.distantPast
            let date2 =
              (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?
              .contentModificationDate ?? Date.distantPast
            return sortAscending ? date1 < date2 : date1 > date2
          case .size:
            let size1 = (try? url1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let size2 = (try? url2.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sortAscending ? size1 < size2 : size1 > size2
          case .dateAdded:
            let date1 =
              (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate
              ?? Date.distantPast
            let date2 =
              (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate
              ?? Date.distantPast
            return sortAscending ? date1 < date2 : date1 > date2
          case .duration:
            // For duration sorting, we'd need to load duration info first
            return sortAscending
              ? url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
                == .orderedAscending
              : url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
                == .orderedDescending
          }
        }
      }

      return sortedVideos
    } catch {
      print("Error loading videos: \(error)")
      return []
    }
  }

  func loadFileInfo(for urls: [URL]) async {
    isLoading = true
    thumbnailsToLoad = urls.count
    thumbnailsLoaded = 0

    // Process in batches for better performance
    let batches = urls.chunked(into: maxConcurrentTasks)

    for batch in batches {
      await withTaskGroup(of: Void.self) { group in
        for url in batch {
          group.addTask { [weak self] in
            await self?.loadSingleFileInfo(url: url)
            await MainActor.run { [weak self] in
              self?.thumbnailsLoaded += 1
            }
          }
        }
      }
    }

    isLoading = false
  }

  private func loadSingleFileInfo(url: URL) async {
    do {
      let asset = AVURLAsset(url: url)

      // Load multiple properties concurrently
      async let duration = asset.load(.duration)
      async let tracks = asset.load(.tracks)

      let loadedDuration = try await duration
      let loadedTracks = try await tracks

      // Get file attributes
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let fileSize = attributes[.size] as? UInt64 ?? 0

      // Process video track info
      let videoTrack = loadedTracks.first { $0.mediaType == .video }
      var resolution = "Unknown"
      var fps = "Unknown"

      if let track = videoTrack {
        async let naturalSize = track.load(.naturalSize)
        async let transform = track.load(.preferredTransform)
        async let nominalFrameRate = track.load(.nominalFrameRate)

        let size = try await naturalSize
        let trackTransform = try await transform
        let frameRate = try await nominalFrameRate

        let transformedSize = size.applying(trackTransform)
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))

        resolution = "\(width)x\(height)"
        fps = String(format: "%.1f", frameRate)
      }

      let info = FileInfo(
        size: formatFileSize(bytes: fileSize),
        duration: formatDuration(loadedDuration.seconds),
        resolution: resolution,
        fps: fps
      )

      await MainActor.run { [weak self] in
        self?.fileInfo[url] = info
      }
    } catch {
      let info = FileInfo(
        size: "Unknown",
        duration: "Unknown",
        resolution: "Unknown",
        fps: "Unknown"
      )
      await MainActor.run { [weak self] in
        self?.fileInfo[url] = info
      }
    }
  }
}

// MARK: - Centralized App State

@MainActor
class AppState: ObservableObject {
  // MARK: - Core Data
  @Published var videoURLs: [URL] = []
  @Published var folderURL: URL? = nil
  @Published var currentIndex: Int = 0
  @Published var player: AVPlayer? = nil

  // MARK: - UI State
  @Published var playbackMode: PlaybackMode = .folderView
  @Published var playbackType: PlaybackType = .clips
  @Published var speedOption: SpeedOption = .x2
  @Published var isMuted: Bool = true

  // MARK: - Sorting & Filtering
  @Published var sortOption: SortOption = .name
  @Published var sortAscending: Bool = true
  @Published var filterSize: FilterSizeOption = .all
  @Published var filterLength: FilterLengthOption = .all
  @Published var filterResolution: FilterResolutionOption = .all
  @Published var filterFileType: FilterFileTypeOption = .all

  // MARK: - Selection State
  @Published var selectedURLs: Set<URL> = []
  @Published var selectionOrder: [URL] = []
  @Published var hoveredBatchRow: URL? = nil

  // MARK: - Configuration
  @Published var numberOfClips: Int = 5
  @Published var clipLength: Int = 3
  @Published var deleteHotkey: String = "d"
  @Published var keepHotkey: String = "k"

  // MARK: - Alert State
  @Published var showAlert = false
  @Published var alertType: AlertType = .fileDelete
  @Published var filesPendingDeletion: [URL] = []
  @Published var folderPendingDeletion: URL? = nil
  @Published var folderDeletionInfo: (fileCount: Int, size: String, name: String)? = nil

  // MARK: - Folder Collection
  @Published var folderCollection: [URL] = []
  @Published var currentFolderIndex: Int = 0

  // MARK: - Computed Properties
  var filteredVideoURLs: [URL] {
    videoURLs.filter { url in
      // Size filter
      if filterSize != .all {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? UInt64
        else { return false }
        if !filterSize.matches(sizeBytes: size) { return false }
      }

      // Length filter
      if filterLength != .all {
        guard let info = fileManager.fileInfo[url],
          let duration = durationInSeconds(from: info.duration)
        else { return false }
        if !filterLength.matches(durationSeconds: duration) { return false }
      }

      // Resolution filter
      if filterResolution != .all {
        guard let info = fileManager.fileInfo[url] else { return false }
        if !filterResolution.matches(resolution: info.resolution) { return false }
      }

      // File type filter
      if filterFileType != .all {
        if !filterFileType.matches(fileExtension: url.pathExtension) { return false }
      }

      return true
    }
  }

  var totalFilesText: String {
    "\(videoURLs.count) files"
  }

  var totalSizeText: String {
    let totalSize = videoURLs.compactMap { url in
      try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64
    }.reduce(0, +)
    return formatFileSize(bytes: totalSize)
  }

  // MARK: - Managers
  let fileManager = FileLoadingManager()
  let hotkeyMonitor = GlobalHotkeyMonitor()

  // MARK: - Actions
  func loadVideosAndThumbnails(from folderURL: URL) async {
    self.folderURL = folderURL

    let loadedURLs = await fileManager.loadVideosAndInfo(
      from: folderURL,
      sortOption: sortOption,
      sortAscending: sortAscending
    )

    // Update UI with videos immediately so they can be seen
    videoURLs = loadedURLs
    currentIndex = 0
    selectedURLs.removeAll()
    selectionOrder.removeAll()

    // Load file info in background without blocking UI
    // This will show progress but won't block the main UI
    Task {
      await fileManager.loadFileInfo(for: loadedURLs)
    }
  }

  func toggleSelection(for url: URL) {
    if selectedURLs.contains(url) {
      selectedURLs.remove(url)
      selectionOrder.removeAll { $0 == url }
    } else {
      selectedURLs.insert(url)
      selectionOrder.append(url)
    }
  }

  func selectAll() {
    selectedURLs = Set(filteredVideoURLs)
    selectionOrder = filteredVideoURLs
  }

  func deselectAll() {
    selectedURLs.removeAll()
    selectionOrder.removeAll()
  }

  func deleteCurrentVideo() {
    guard currentIndex < videoURLs.count else { return }
    let url = videoURLs[currentIndex]
    filesPendingDeletion = [url]
    alertType = .fileDelete
    showAlert = true
  }

  func deleteSelectedVideos() {
    filesPendingDeletion = Array(selectedURLs)
    alertType = .fileDelete
    showAlert = true
  }

  func skipCurrentVideo() {
    guard currentIndex < videoURLs.count else { return }
    currentIndex = min(currentIndex + 1, videoURLs.count - 1)
  }

  func setupHotkeyMonitoring() {
    hotkeyMonitor.onSpace = { [weak self] in
      // Handle spacebar
    }
    hotkeyMonitor.onDelete = { [weak self] in
      if self?.playbackMode == .single || self?.playbackMode == .sideBySide {
        self?.deleteCurrentVideo()
      }
    }
    hotkeyMonitor.onKeep = { [weak self] in
      if self?.playbackMode == .single || self?.playbackMode == .sideBySide {
        self?.skipCurrentVideo()
      }
    }
    hotkeyMonitor.deleteKey = deleteHotkey
    hotkeyMonitor.keepKey = keepHotkey
    hotkeyMonitor.startMonitoring()
  }
}

// MARK: - Array Extension for Chunking

extension Array {
  func chunked(into size: Int) -> [[Element]] {
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}
