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

  private let maxConcurrentTasks = 1  // CRITICAL FIX: Keep at 1 to prevent crashes

  func loadVideosAndInfo(
    from folderURL: URL, sortOption: SortOption, sortAscending: Bool
  ) async
    -> [URL]
  {
    do {
      // PERFORMANCE FIX: Use faster file operations with shorter timeout
      let contents = try await withTimeout(10.0) {  // Reduced timeout to 10 seconds
        return try await Task.detached {
          let fileManager = FileManager.default
          let result = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [
              .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            ]
          )

          return result
        }.value
      }

      let videos = await Task.detached {
        let fileManager = FileManager.default
        let result = contents.filter { fileManager.isVideoFile($0) }

        return result
      }.value

      // PERFORMANCE FIX: More aggressive limiting for very large folders
      let maxVideosToProcess = min(videos.count, 1000)  // Reduced cap to 1000 videos
      let videosToProcess = Array(videos.prefix(maxVideosToProcess))

      // PERFORMANCE FIX: Process files more efficiently to avoid blocking
      var videoResourceValues: [URL: URLResourceValues?] = [:]

      for (index, video) in videosToProcess.enumerated() {
        // Check for cancellation more frequently
        if index % 25 == 0 && Task.isCancelled {  // Check every 25 items instead of 50
          break
        }

        do {
          let resourceValues = try await Task.detached {
            let result = try video.resourceValues(forKeys: [
              .fileSizeKey,
              .contentModificationDateKey,
              .creationDateKey,
            ])

            return result
          }.value

          videoResourceValues[video] = resourceValues

        } catch {
          videoResourceValues[video] = nil
        }
      }

      // Optimized sorting with timeout and pre-loaded resource values
      let sortedVideos = await Task.detached {
        return videosToProcess.sorted { url1, url2 in
          switch sortOption {
          case .name:
            let comparison = url1.lastPathComponent.localizedStandardCompare(
              url2.lastPathComponent)
            return sortAscending
              ? comparison == .orderedAscending : comparison == .orderedDescending

          case .size:
            let size1 = videoResourceValues[url1]??.fileSize ?? 0
            let size2 = videoResourceValues[url2]??.fileSize ?? 0
            return sortAscending ? size1 < size2 : size1 > size2

          case .dateModified:
            let date1 = videoResourceValues[url1]??.contentModificationDate ?? Date.distantPast
            let date2 = videoResourceValues[url2]??.contentModificationDate ?? Date.distantPast
            return sortAscending ? date1 < date2 : date1 > date2

          case .dateAdded:
            let date1 = videoResourceValues[url1]??.creationDate ?? Date.distantPast
            let date2 = videoResourceValues[url2]??.creationDate ?? Date.distantPast
            return sortAscending ? date1 < date2 : date1 > date2

          case .duration:
            // For duration sorting, fall back to name sorting since we don't load duration info upfront
            let comparison = url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
            return sortAscending
              ? comparison == .orderedAscending : comparison == .orderedDescending
          }
        }
      }.value

      return sortedVideos

    } catch {
      // Return empty array on error instead of crashing
      return []
    }
  }

  func loadFileInfo(for urls: [URL]) async {
    await loadFileInfoWithProgress(for: urls) { _, _ in }
  }

  func loadFileInfoWithProgress(
    for urls: [URL], progressCallback: @escaping (Double, String) -> Void
  ) async {
    isLoading = true
    thumbnailsToLoad = urls.count
    thumbnailsLoaded = 0

    // PERFORMANCE FIX: Process files more efficiently
    for (index, url) in urls.enumerated() {
      let progress = Double(index) / Double(urls.count)
      progressCallback(
        progress,
        "Loading file info (\(index + 1) of \(urls.count))..."
      )

      await loadSingleFileInfo(url: url)
      thumbnailsLoaded += 1

      // PERFORMANCE FIX: Shorter delay to speed up processing
      try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms delay - reduced from 25ms
    }

    progressCallback(1.0, "File info loaded")

    // CRITICAL FIX: Properly dismiss the loading indicator
    isLoading = false
  }

  private func loadSingleFileInfo(url: URL) async {
    do {
      // PERFORMANCE FIX: Reduce timeout to 1.5 seconds for faster processing
      let info = try await withTimeout(1.5) {
        return try await self.extractFileInfoWithTimeout(url: url)
      }

      await MainActor.run { [weak self] in
        self?.fileInfo[url] = info
      }
    } catch {
      // Fallback to basic file info using detached task
      let basicInfo = await Task.detached {
        return await self.getBasicFileInfo(url: url)
      }.value

      await MainActor.run { [weak self] in
        self?.fileInfo[url] = basicInfo
      }
    }
  }

  private func extractFileInfoWithTimeout(url: URL) async throws -> FileInfo {
    // PERFORMANCE FIX: Run ALL AVAsset operations in a detached task
    return try await Task.detached {
      let asset = AVURLAsset(url: url)

      // Get file attributes first (this is fast)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let fileSize = attributes[.size] as? UInt64 ?? 0

      // PERFORMANCE FIX: Ultra-aggressive timeout for duration loading
      let duration: CMTime
      do {
        duration = try await withTimeout(0.8) {  // Reduced to 0.8 seconds
          return try await asset.load(.duration)
        }
      } catch {
        // Use a fallback duration if loading times out
        duration = CMTime.zero
      }

      // PERFORMANCE FIX: Skip all track/resolution loading as it's causing freezes
      let resolution = "Unknown"
      let fps = "Unknown"

      return FileInfo(
        size: formatFileSize(bytes: fileSize),
        duration: formatDuration(duration.seconds),
        resolution: resolution,
        fps: fps
      )
    }.value
  }

  private func getBasicFileInfo(url: URL) async -> FileInfo {
    // CRITICAL FIX: Run file operations in detached task
    return await Task.detached {
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0

        return FileInfo(
          size: formatFileSize(bytes: fileSize),
          duration: "Unknown",
          resolution: "Unknown",
          fps: "Unknown"
        )
      } catch {
        return FileInfo(
          size: "Unknown",
          duration: "Unknown",
          resolution: "Unknown",
          fps: "Unknown"
        )
      }
    }.value
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
  @Published var hoveredVideoURL: URL? = nil
  @Published var preloadCount: Int = 2
  @Published var visibleVideosInList: Set<URL> = []
  @Published var videosToPlay: Set<URL> = []

  // CRITICAL FIX: Pre-loaded folder thumbnails (never unload these!)
  @Published var folderThumbnails: [URL: Image] = [:]

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
  @Published var lastSelectedURL: URL? = nil
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

  // MARK: - Loading State
  @Published var isLoadingFolders = false
  @Published var loadingProgress: Double = 0.0
  @Published var loadingMessage: String = ""
  @Published var folderNavigationInProgress = false

  // CRITICAL FIX: Task management for crash prevention
  private var currentFolderLoadingTask: Task<Void, Never>? = nil
  private var currentThumbnailLoadingTask: Task<Void, Never>?

  // MARK: - Computed Properties
  var filteredVideoURLs: [URL] {
    videoURLs.filter { url in
      // Size filter - use cached fileInfo instead of synchronous file operations
      if filterSize != .all {
        if let info = fileManager.fileInfo[url],
          let sizeString = info.size.components(separatedBy: " ").first,
          let sizeValue = Double(sizeString)
        {
          // Convert back to bytes for filtering
          let multiplier: UInt64
          if info.size.contains("GB") {
            multiplier = 1_000_000_000
          } else if info.size.contains("MB") {
            multiplier = 1_000_000
          } else if info.size.contains("KB") {
            multiplier = 1_000
          } else {
            multiplier = 1
          }
          let sizeBytes = UInt64(sizeValue * Double(multiplier))
          if !filterSize.matches(sizeBytes: sizeBytes) { return false }
        } else {
          // If no cached info available, skip filter (don't block on file operations)
          return true
        }
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
    // Use cached file info instead of synchronous file operations
    let totalSize = videoURLs.compactMap { url in
      guard let info = fileManager.fileInfo[url],
        let sizeString = info.size.components(separatedBy: " ").first,
        let sizeValue = Double(sizeString)
      else { return UInt64(0) }

      // Convert back to bytes
      let multiplier: UInt64
      if info.size.contains("GB") {
        multiplier = 1_000_000_000
      } else if info.size.contains("MB") {
        multiplier = 1_000_000
      } else if info.size.contains("KB") {
        multiplier = 1_000
      } else {
        multiplier = 1
      }
      return UInt64(sizeValue * Double(multiplier))
    }.reduce(0, +)
    return formatFileSize(bytes: totalSize)
  }

  // MARK: - Video Preloading Logic
  func shouldPlayVideo(_ url: URL, hoveredURL: URL?) -> Bool {
    guard let hoveredURL = hoveredURL else {
      return false
    }

    // PERFORMANCE FIX: ONLY play the directly hovered video to prevent multiple simultaneous players
    // This is the critical fix for preventing freezing and resource exhaustion
    return url == hoveredURL
  }

  // MARK: - Batch List Viewport Logic
  func shouldPlayVideoInList(_ url: URL) -> Bool {
    // PERFORMANCE FIX: In list mode, only play if this is the directly hovered video
    guard let hoveredURL = hoveredVideoURL else { return false }
    return url == hoveredURL
  }

  func videoDidBecomeVisible(_ url: URL) {
    // Silent visibility tracking
    visibleVideosInList.insert(url)

    // Delay before adding to play list to avoid rapid changes during scrolling
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self = self, self.visibleVideosInList.contains(url) else { return }
      // Video is still visible after delay, can be considered for playback
    }
  }

  func videoDidBecomeInvisible(_ url: URL) {
    // Silent invisibility tracking
    visibleVideosInList.remove(url)
  }

  // MARK: - Managers
  let fileManager = FileLoadingManager()
  let hotkeyMonitor = GlobalHotkeyMonitor()

  // MARK: - Actions
  func loadVideosAndThumbnails(from folderURL: URL) async {
    await loadVideosAndThumbnailsWithProgress(from: folderURL)
  }

  // CRITICAL FIX: FAST thumbnail loading like a file manager - no more blocking nonsense
  private func loadVideosAndThumbnailsWithProgress(from folderURL: URL) async {
    await MainActor.run {
      isLoadingFolders = true
      loadingProgress = 0.0
      loadingMessage = "Loading folder..."
    }

    defer {
      Task { @MainActor in
        isLoadingFolders = false
        folderNavigationInProgress = false
      }
    }

    do {
      // Step 1: Load file list FAST
      await MainActor.run {
        loadingProgress = 0.2
        loadingMessage = "Scanning video files..."
      }

      let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .nameKey,
      ]

      let fileURLs = try FileManager.default.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: resourceKeys,
        options: [.skipsHiddenFiles]
      )

      // Filter video files
      let videoExtensions = Set(["mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm"])
      var filteredURLs = fileURLs.filter { url in
        guard let resourceValues = try? url.resourceValues(forKeys: Set(resourceKeys)),
          resourceValues.isRegularFile == true
        else {
          return false
        }
        return videoExtensions.contains(url.pathExtension.lowercased())
      }

      // Apply size limit for performance
      if filteredURLs.count > 1000 {
        filteredURLs = Array(filteredURLs.prefix(1000))
      }

      // Step 2: Update UI IMMEDIATELY - no waiting for thumbnails
      await MainActor.run {
        loadingProgress = 0.8
        loadingMessage = "Finalizing..."

        self.videoURLs = filteredURLs
        self.folderURL = folderURL
        self.selectedURLs.removeAll()
        self.selectionOrder.removeAll()
        self.hoveredVideoURL = nil

        // Clear old thumbnails
        folderThumbnails.removeAll()
      }

      // Step 3: Load thumbnails FAST in background like a file manager
      await MainActor.run {
        loadingProgress = 1.0
        loadingMessage = "Complete!"
      }

      // CRITICAL FIX: Properly dismiss loading indicator after reaching 100%
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        self.isLoadingFolders = false
        self.folderNavigationInProgress = false
      }

      // Start fast background thumbnail loading
      startFastThumbnailLoading(for: filteredURLs)

      // Load file info in background (non-blocking)
      await fileManager.loadFileInfo(for: filteredURLs)

    } catch {
      await MainActor.run {
        self.videoURLs = []
        self.folderURL = folderURL
        self.selectedURLs.removeAll()
        self.selectionOrder.removeAll()
        loadingMessage = "Error loading folder"
      }
    }
  }

  // NEW: FAST thumbnail loading optimized for large folders (536+ videos)
  private func startFastThumbnailLoading(for urls: [URL]) {
    // Cancel any existing thumbnail loading
    currentThumbnailLoadingTask?.cancel()

    currentThumbnailLoadingTask = Task {
      // OPTIMIZED: For large folders, use controlled concurrency to prevent system overload
      let maxConcurrentTasks = 8  // Reduced from unlimited to prevent overwhelming system

      await withTaskGroup(of: Void.self) { group in
        var urlIterator = urls.makeIterator()
        var activeTasks = 0

        // Start initial batch
        while activeTasks < maxConcurrentTasks, let url = urlIterator.next() {
          activeTasks += 1

          group.addTask { [weak self] in
            defer { activeTasks -= 1 }
            guard let self = self else { return }

            // Check for cancellation
            if Task.isCancelled { return }

            // Generate thumbnail with 2% timing
            if let thumbnail = await self.generateFastThumbnail(url: url) {
              await MainActor.run {
                self.folderThumbnails[url] = thumbnail
              }
            }
          }
        }

        // Process remaining URLs as tasks complete
        for await _ in group {
          // Start next task if more URLs available
          if let url = urlIterator.next() {
            activeTasks += 1

            group.addTask { [weak self] in
              defer { activeTasks -= 1 }
              guard let self = self else { return }

              if Task.isCancelled { return }

              if let thumbnail = await self.generateFastThumbnail(url: url) {
                await MainActor.run {
                  self.folderThumbnails[url] = thumbnail
                }
              }
            }
          }
        }
      }
    }
  }

  // NEW: Super fast thumbnail generation like file managers - FIXED race condition
  private func generateFastThumbnail(url: URL) async -> Image? {
    return await withCheckedContinuation { continuation in
      let asset = AVAsset(url: url)
      let imageGenerator = AVAssetImageGenerator(asset: asset)

      // OPTIMIZED settings for large folders (536 videos)
      imageGenerator.appliesPreferredTrackTransform = true
      imageGenerator.maximumSize = CGSize(width: 200, height: 200)  // Balanced size for performance
      imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
      imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

      // CRITICAL FIX: Use 2% timing like before - much better quality than 0.5 seconds
      let duration = asset.duration
      let targetTime: CMTime
      if duration.isValid && duration.seconds > 0 {
        // Use 2% of video duration, minimum 1 second
        let seekTime = max(duration.seconds * 0.02, 1.0)
        targetTime = CMTime(seconds: seekTime, preferredTimescale: 600)
      } else {
        // Fallback to 1 second if duration unavailable
        targetTime = CMTime(seconds: 1.0, preferredTimescale: 600)
      }

      // CRITICAL FIX: Use atomic class to prevent double-resume
      final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false

        func tryResume(_ continuation: CheckedContinuation<Image?, Never>, with result: Image?)
          -> Bool
        {
          lock.lock()
          defer { lock.unlock() }

          if !hasResumed {
            hasResumed = true
            continuation.resume(returning: result)
            return true
          }
          return false
        }
      }

      let resumeGuard = ResumeGuard()

      // Longer timeout for 2% timing (needs more time than 0.5 seconds)
      let timeoutTask = Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 second timeout for 2% timing
        _ = resumeGuard.tryResume(continuation, with: nil)
      }

      imageGenerator.generateCGImageAsynchronously(for: targetTime) { cgImage, actualTime, error in
        timeoutTask.cancel()

        if let cgImage = cgImage {
          let nsImage = NSImage(cgImage: cgImage, size: NSSize.zero)
          let image = Image(nsImage: nsImage)
          _ = resumeGuard.tryResume(continuation, with: image)
        } else {
          _ = resumeGuard.tryResume(continuation, with: nil)
        }
      }
    }
  }

  // CRITICAL FIX: New function to handle sorting without reloading the folder
  func applySorting() async {
    guard !videoURLs.isEmpty else {
      return
    }

    // Capture values needed for sorting
    let currentVideoURLs = videoURLs
    let currentSortOption = sortOption
    let currentSortAscending = sortAscending
    let currentFileInfo = fileManager.fileInfo

    // Sort the existing videoURLs array without reloading from disk
    let sortedURLs = await Task.detached {
      let result = currentVideoURLs.sorted { url1, url2 in
        switch currentSortOption {
        case .name:
          return currentSortAscending
            ? url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
              == .orderedAscending
            : url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
              == .orderedDescending
        case .dateModified:
          // For now, fall back to name sorting since we don't have proper date info
          return currentSortAscending
            ? url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
              == .orderedAscending
            : url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
              == .orderedDescending
        case .size:
          // Use cached file info for size sorting
          let size1 = Self.fileSizeInBytes(from: currentFileInfo[url1]?.size ?? "0 bytes")
          let size2 = Self.fileSizeInBytes(from: currentFileInfo[url2]?.size ?? "0 bytes")
          return currentSortAscending ? size1 < size2 : size1 > size2
        case .dateAdded, .duration:
          // For now, fall back to name sorting for these options
          return currentSortAscending
            ? url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
              == .orderedAscending
            : url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
              == .orderedDescending
        }
      }

      return result
    }.value

    videoURLs = sortedURLs
  }

  // Helper function to convert file size string back to bytes for sorting
  private nonisolated static func fileSizeInBytes(from sizeString: String) -> UInt64 {
    let components = sizeString.components(separatedBy: " ")
    guard let sizeValue = Double(components.first ?? "0") else { return 0 }

    let multiplier: UInt64
    if sizeString.contains("GB") {
      multiplier = 1_000_000_000
    } else if sizeString.contains("MB") {
      multiplier = 1_000_000
    } else if sizeString.contains("KB") {
      multiplier = 1_000
    } else {
      multiplier = 1
    }

    return UInt64(sizeValue * Double(multiplier))
  }

  func loadMultipleFolders(_ selectedFolders: [URL]) async {
    isLoadingFolders = true
    loadingProgress = 0.0
    loadingMessage = "Scanning folders..."

    var allFolders: [URL] = []

    // Process each selected folder and its subfolders
    for (index, folderURL) in selectedFolders.enumerated() {
      loadingMessage =
        "Scanning folder \(index + 1) of \(selectedFolders.count): \(folderURL.lastPathComponent)"
      loadingProgress = Double(index) / Double(selectedFolders.count) * 0.3  // 30% for folder scanning

      // Add the folder itself
      allFolders.append(folderURL)

      // Find subfolders asynchronously
      do {
        let subfolders = try await Task.detached {
          let fileManager = FileManager.default
          let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
          )

          let subfolders = contents.filter { url in
            do {
              let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
              return resourceValues.isDirectory == true
            } catch {
              return false
            }
          }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
          }

          return subfolders
        }.value

        allFolders.append(contentsOf: subfolders)
      } catch {
        // Continue with other folders if one fails
      }
    }

    // Update folder collection
    folderCollection = allFolders
    currentFolderIndex = 0

    // Load the first folder with improved performance
    if let firstFolder = allFolders.first {
      await loadVideosAndThumbnailsWithProgress(from: firstFolder)
    }

    isLoadingFolders = false
  }

  func loadFolderWithSubfolders(from rootFolderURL: URL) async {
    await loadMultipleFolders([rootFolderURL])
  }

  func navigateToPreviousFolder() {
    guard currentFolderIndex > 0 else { return }

    // CRITICAL FIX: Set navigation state immediately for immediate UI feedback
    folderNavigationInProgress = true
    isLoadingFolders = true

    // Cancel any ongoing operations
    cancelCurrentOperations()

    currentFolderIndex -= 1
    let folderURL = folderCollection[currentFolderIndex]

    currentFolderLoadingTask = Task {
      await loadVideosAndThumbnailsWithProgress(from: folderURL)
      isLoadingFolders = false
      folderNavigationInProgress = false
    }
  }

  func navigateToNextFolder() {
    guard currentFolderIndex < folderCollection.count - 1 else {
      return
    }

    // CRITICAL FIX: Set navigation state immediately for immediate UI feedback
    folderNavigationInProgress = true
    isLoadingFolders = true

    // Cancel any ongoing operations
    cancelCurrentOperations()

    currentFolderIndex += 1
    let folderURL = folderCollection[currentFolderIndex]

    currentFolderLoadingTask = Task {
      await loadVideosAndThumbnailsWithProgress(from: folderURL)
      isLoadingFolders = false
      folderNavigationInProgress = false
    }
  }

  // CRITICAL FIX: Cancel all ongoing operations to prevent crashes
  private func cancelCurrentOperations() {
    currentFolderLoadingTask?.cancel()
    currentFolderLoadingTask = nil

    currentThumbnailLoadingTask?.cancel()
    currentThumbnailLoadingTask = nil

    // CRITICAL FIX: Use stronger cancellation to stop all thumbnail operations immediately
    ThumbnailCache.shared.cancelAllRequests()

    // Clear any pending thumbnail requests
    folderThumbnails.removeAll()
  }

  func deleteCurrentFolder() {
    guard currentFolderIndex < folderCollection.count else { return }
    let folderURL = folderCollection[currentFolderIndex]

    // Calculate folder info for confirmation asynchronously
    Task {
      do {
        let (videoCount, totalSize) = try await Task.detached {
          let fileManager = FileManager.default
          let contents = try fileManager.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.fileSizeKey])
          let videoFiles = contents.filter { fileManager.isVideoFile($0) }

          let totalSize = videoFiles.compactMap { url in
            try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
          }.reduce(0, +)

          return (videoFiles.count, totalSize)
        }.value

        await MainActor.run {
          self.folderPendingDeletion = folderURL
          self.folderDeletionInfo = (
            fileCount: videoCount,
            size: formatFileSize(bytes: UInt64(totalSize)),
            name: folderURL.lastPathComponent
          )
          self.alertType = .folderDelete
          self.showAlert = true
        }
      } catch {
        // Silent error handling
        await MainActor.run {
          // Still show alert with minimal info if calculation fails
          self.folderPendingDeletion = folderURL
          self.folderDeletionInfo = (
            fileCount: 0,
            size: "Unknown",
            name: folderURL.lastPathComponent
          )
          self.alertType = .folderDelete
          self.showAlert = true
        }
      }
    }
  }

  func toggleSelection(for url: URL) {
    if selectedURLs.contains(url) {
      selectedURLs.remove(url)
      selectionOrder.removeAll { $0 == url }
    } else {
      selectedURLs.insert(url)
      selectionOrder.append(url)
      lastSelectedURL = url
    }
  }

  func selectRange(to url: URL) {
    guard let lastSelectedURL = selectionOrder.last,
      let startIndex = filteredVideoURLs.firstIndex(of: lastSelectedURL),
      let endIndex = filteredVideoURLs.firstIndex(of: url)
    else {
      // If no previous selection, just select this one
      toggleSelection(for: url)
      return
    }

    let range = min(startIndex, endIndex)...max(startIndex, endIndex)
    for index in range {
      let urlToSelect = filteredVideoURLs[index]
      if !selectedURLs.contains(urlToSelect) {
        selectedURLs.insert(urlToSelect)
        selectionOrder.append(urlToSelect)
      }
    }
  }

  func selectAll() {
    selectedURLs = Set(filteredVideoURLs)
    selectionOrder = filteredVideoURLs
    lastSelectedURL = filteredVideoURLs.last
  }

  func deselectAll() {
    selectedURLs.removeAll()
    selectionOrder.removeAll()
    lastSelectedURL = nil
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
      self?.handleSpaceKeyPress()
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

  func handleSpaceKeyPress() {
    // Open selected videos in Spotlight (QuickLook)
    let urlsToPreview: [URL]

    if !selectedURLs.isEmpty {
      // Use selected videos in selection order
      urlsToPreview = selectionOrder.filter { selectedURLs.contains($0) }
    } else if playbackMode == .single || playbackMode == .sideBySide {
      // Use current video in single/side-by-side mode
      guard currentIndex < videoURLs.count else { return }
      urlsToPreview = [videoURLs[currentIndex]]
    } else {
      // No selection and not in single mode - do nothing
      return
    }

    if !urlsToPreview.isEmpty {
      QuickLookPreviewCoordinator.shared.preview(urls: urlsToPreview)
    }
  }

  func openInFileManager(url: URL) {
    // Silent file manager operation
    _ = NSWorkspace.shared.activateFileViewerSelecting([url])
    // No logging for success/failure
  }

  func handleShiftClick(url: URL) {
    selectRange(to: url)
  }
}
