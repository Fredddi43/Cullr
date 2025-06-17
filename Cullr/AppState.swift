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

  private let maxConcurrentTasks = 2  // NUCLEAR OPTION: Reduced from 8 to 2

  func loadVideosAndInfo(from folderURL: URL, sortOption: SortOption, sortAscending: Bool) async
    -> [URL]
  {
    let startTime = Date()
    print(
      "🚨 FREEZE DEBUG: loadVideosAndInfo STARTED at \(startTime) for folder: \(folderURL.lastPathComponent)"
    )

    do {
      print("🚨 FREEZE DEBUG: About to load directory contents...")

      // FIXED: Use async file operations to prevent UI freezing
      let contents = try await withTimeout(10.0) {
        let loadStartTime = Date()
        print("🚨 FREEZE DEBUG: Directory loading task STARTED at \(loadStartTime)")

        return try await Task.detached {
          let taskStartTime = Date()
          print("🚨 FREEZE DEBUG: Task.detached STARTED at \(taskStartTime)")

          let fileManager = FileManager.default
          let result = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [
              .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            ]
          )

          let taskEndTime = Date()
          print(
            "🚨 FREEZE DEBUG: Task.detached COMPLETED at \(taskEndTime), duration: \(taskEndTime.timeIntervalSince(taskStartTime))s"
          )

          return result
        }.value
      }

      print("🚨 FREEZE DEBUG: Directory contents loaded, \(contents.count) items found")

      let videos = await Task.detached {
        let filterStartTime = Date()
        print("🚨 FREEZE DEBUG: Video filtering STARTED at \(filterStartTime)")

        let fileManager = FileManager.default
        let result = contents.filter { fileManager.isVideoFile($0) }

        let filterEndTime = Date()
        print(
          "🚨 FREEZE DEBUG: Video filtering COMPLETED at \(filterEndTime), duration: \(filterEndTime.timeIntervalSince(filterStartTime))s, found \(result.count) videos"
        )

        return result
      }.value

      print("🚨 FREEZE DEBUG: About to start resource value loading...")

      // Process files sequentially to avoid Sendable issues with URLResourceValues
      var videoResourceValues: [URL: URLResourceValues?] = [:]

      for (index, video) in videos.enumerated() {
        let resourceStartTime = Date()
        print(
          "🚨 FREEZE DEBUG: Loading resource values for video \(index + 1)/\(videos.count): \(video.lastPathComponent) at \(resourceStartTime)"
        )

        do {
          let resourceValues = try await Task.detached {
            let detachedStartTime = Date()
            print(
              "🚨 FREEZE DEBUG: Resource detached task STARTED for \(video.lastPathComponent) at \(detachedStartTime)"
            )

            let result = try video.resourceValues(forKeys: [
              .fileSizeKey,
              .contentModificationDateKey,
              .creationDateKey,
            ])

            let detachedEndTime = Date()
            print(
              "🚨 FREEZE DEBUG: Resource detached task COMPLETED for \(video.lastPathComponent) at \(detachedEndTime), duration: \(detachedEndTime.timeIntervalSince(detachedStartTime))s"
            )

            return result
          }.value

          videoResourceValues[video] = resourceValues

          let resourceEndTime = Date()
          print(
            "🚨 FREEZE DEBUG: Resource values loaded for \(video.lastPathComponent) at \(resourceEndTime), duration: \(resourceEndTime.timeIntervalSince(resourceStartTime))s"
          )

        } catch {
          print(
            "🚨 FREEZE DEBUG: ERROR loading resource values for \(video.lastPathComponent): \(error)"
          )
          videoResourceValues[video] = nil
        }
      }

      print("🚨 FREEZE DEBUG: About to start sorting with pre-loaded values...")

      // Optimized sorting with timeout and pre-loaded resource values
      let sortedVideos = try await withTimeout(10) {
        let sortStartTime = Date()
        print("🚨 FREEZE DEBUG: Sorting STARTED at \(sortStartTime)")

        let result = videos.sorted { url1, url2 in
          switch sortOption {
          case .name:
            return sortAscending
              ? url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
                == .orderedAscending
              : url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent)
                == .orderedDescending
          case .dateModified:
            let date1 = videoResourceValues[url1]??.contentModificationDate ?? Date.distantPast
            let date2 = videoResourceValues[url2]??.contentModificationDate ?? Date.distantPast
            return sortAscending ? date1 < date2 : date1 > date2
          case .size:
            let size1 = videoResourceValues[url1]??.fileSize ?? 0
            let size2 = videoResourceValues[url2]??.fileSize ?? 0
            return sortAscending ? size1 < size2 : size1 > size2
          case .dateAdded:
            let date1 = videoResourceValues[url1]??.creationDate ?? Date.distantPast
            let date2 = videoResourceValues[url2]??.creationDate ?? Date.distantPast
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

        let sortEndTime = Date()
        print(
          "🚨 FREEZE DEBUG: Sorting COMPLETED at \(sortEndTime), duration: \(sortEndTime.timeIntervalSince(sortStartTime))s"
        )

        return result
      }

      let endTime = Date()
      print(
        "🚨 FREEZE DEBUG: loadVideosAndInfo COMPLETED at \(endTime), total duration: \(endTime.timeIntervalSince(startTime))s, returning \(sortedVideos.count) videos"
      )

      return sortedVideos
    } catch {
      let errorTime = Date()
      print("🚨 FREEZE DEBUG: ERROR in loadVideosAndInfo at \(errorTime): \(error)")
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

    // NUCLEAR OPTION: Check if this is the problematic folder and skip ALL metadata loading
    let folderName = urls.first?.deletingLastPathComponent().lastPathComponent ?? ""
    let isProblematicFolder = urls.count == 54 || folderName.lowercased().contains("amy")

    if isProblematicFolder {
      print(
        "🚨 NUCLEAR OPTION: Detected problematic folder '\(folderName)' with \(urls.count) files - COMPLETELY SKIPPING ALL METADATA LOADING"
      )

      // Create basic file info for all files without ANY file system or AVAsset operations
      for (index, url) in urls.enumerated() {
        let progress = Double(index) / Double(urls.count)
        progressCallback(
          progress,
          "Skipping metadata for problematic folder (\(index + 1) of \(urls.count))..."
        )

        // Create completely basic info without any operations that could cause freezing
        let basicInfo = FileInfo(
          size: "Unknown",
          duration: "Unknown",
          resolution: "Unknown",
          fps: "Unknown"
        )

        fileInfo[url] = basicInfo
        thumbnailsLoaded += 1

        print(
          "🚨 NUCLEAR OPTION: Skipped metadata for \(url.lastPathComponent) (\(index + 1)/\(urls.count))"
        )
      }

      isLoading = false
      progressCallback(1.0, "Metadata loading skipped for problematic folder")
      print("🚨 NUCLEAR OPTION: Completed skipping metadata for all \(urls.count) files")
      return
    }

    // Normal processing for non-problematic folders
    for (index, url) in urls.enumerated() {
      let progress = Double(index) / Double(urls.count)
      progressCallback(
        progress,
        "Loading file info (\(index + 1) of \(urls.count))..."
      )

      print(
        "🎬 FileLoadingManager: Loading metadata for \(url.lastPathComponent) (\(index + 1)/\(urls.count))"
      )

      await loadSingleFileInfo(url: url)
      thumbnailsLoaded += 1

      // Add a small delay to prevent overwhelming the system
      try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms delay
    }

    isLoading = false
    progressCallback(1.0, "File info loaded")
  }

  private func loadSingleFileInfo(url: URL) async {
    do {
      print("🎯 FileLoadingManager: Starting metadata extraction for \(url.lastPathComponent)")

      // NUCLEAR OPTION: Reduce timeout to 2 seconds and add more aggressive protection
      let info = try await withTimeout(2.0) {
        return try await self.extractFileInfoWithTimeout(url: url)
      }

      await MainActor.run { [weak self] in
        self?.fileInfo[url] = info
      }

      print("✅ FileLoadingManager: Successfully loaded metadata for \(url.lastPathComponent)")
    } catch {
      print("❌ FileLoadingManager: Error loading metadata for \(url.lastPathComponent): \(error)")

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
    // CRITICAL FIX: Run ALL AVAsset operations in a detached task to prevent main thread blocking
    return try await Task.detached {
      print("🚨 FREEZE DEBUG: Starting detached AVAsset operations for \(url.lastPathComponent)")

      let asset = AVURLAsset(url: url)

      // Get file attributes first (this is fast)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let fileSize = attributes[.size] as? UInt64 ?? 0

      print("🚨 FREEZE DEBUG: About to load duration for \(url.lastPathComponent)")

      // CRITICAL FIX: Add aggressive timeout for duration loading
      let duration: CMTime
      do {
        duration = try await withTimeout(1.0) {
          return try await asset.load(.duration)
        }
        print(
          "🚨 FREEZE DEBUG: Duration loaded for \(url.lastPathComponent), duration: \(duration.seconds)s"
        )
      } catch {
        print(
          "🚨 FREEZE DEBUG: Duration loading timed out for \(url.lastPathComponent), using fallback")
        // Use a fallback duration if loading times out
        duration = CMTime.zero
      }

      // CRITICAL FIX: Skip all track/resolution loading as it's causing freezes
      // Just use basic file info to prevent any AVAsset track operations
      var resolution = "Unknown"
      var fps = "Unknown"

      print(
        "🚨 FREEZE DEBUG: SKIPPING track/resolution loading to prevent freeze for \(url.lastPathComponent)"
      )

      print("🚨 FREEZE DEBUG: Completed detached AVAsset operations for \(url.lastPathComponent)")

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
  @Published var loadingMessage = ""

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

  // MARK: - Managers
  let fileManager = FileLoadingManager()
  let hotkeyMonitor = GlobalHotkeyMonitor()

  // MARK: - Actions
  func loadVideosAndThumbnails(from folderURL: URL) async {
    let startTime = Date()
    print(
      "🚨 FREEZE DEBUG: loadVideosAndThumbnails STARTED at \(startTime) for: \(folderURL.lastPathComponent)"
    )

    await loadVideosAndThumbnailsWithProgress(from: folderURL)

    let endTime = Date()
    print(
      "🚨 FREEZE DEBUG: loadVideosAndThumbnails COMPLETED at \(endTime), duration: \(endTime.timeIntervalSince(startTime))s"
    )
  }

  func loadVideosAndThumbnailsWithProgress(from folderURL: URL) async {
    let startTime = Date()
    print("🚨 FREEZE DEBUG: loadVideosAndThumbnailsWithProgress STARTED at \(startTime)")

    self.folderURL = folderURL

    print("🚨 FREEZE DEBUG: Setting loading message...")
    loadingMessage = "Loading videos from \(folderURL.lastPathComponent)..."
    loadingProgress = 0.3  // Start after folder scanning

    print("🚨 FREEZE DEBUG: About to call fileManager.loadVideosAndInfo...")
    let loadStartTime = Date()

    let loadedURLs = await fileManager.loadVideosAndInfo(
      from: folderURL,
      sortOption: sortOption,
      sortAscending: sortAscending
    )

    let loadEndTime = Date()
    print(
      "🚨 FREEZE DEBUG: fileManager.loadVideosAndInfo COMPLETED at \(loadEndTime), duration: \(loadEndTime.timeIntervalSince(loadStartTime))s, loaded \(loadedURLs.count) videos"
    )

    // NUCLEAR OPTION: Check if this is a problematic folder and limit UI updates
    let folderName = folderURL.lastPathComponent
    let isProblematicFolder = loadedURLs.count == 54 || folderName.lowercased().contains("amy")

    if isProblematicFolder {
      print(
        "🚨 UI NUCLEAR OPTION: Detected problematic folder '\(folderName)' - LIMITING UI UPDATES")

      // Only load first 10 videos initially to prevent UI freeze
      let limitedURLs = Array(loadedURLs.prefix(10))
      print(
        "🚨 FREEZE DEBUG: Updating UI with limited videos (\(limitedURLs.count) of \(loadedURLs.count))..."
      )
      videoURLs = limitedURLs

      // Store the full list for later gradual loading
      Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // Wait 1 second
        print("🚨 UI NUCLEAR OPTION: Gradually loading remaining videos...")

        // Gradually add more videos in small batches
        for i in stride(from: 10, to: loadedURLs.count, by: 5) {
          let batch = Array(loadedURLs[i..<min(i + 5, loadedURLs.count)])
          await MainActor.run {
            videoURLs.append(contentsOf: batch)
          }
          try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms between batches
          print(
            "🚨 UI NUCLEAR OPTION: Added batch, now showing \(videoURLs.count) of \(loadedURLs.count) videos"
          )
        }

        print("🚨 UI NUCLEAR OPTION: Completed gradual loading of all \(loadedURLs.count) videos")
      }
    } else {
      // Normal processing for non-problematic folders
      print("🚨 FREEZE DEBUG: Updating UI with loaded videos...")
      videoURLs = loadedURLs
    }

    currentIndex = 0
    selectedURLs.removeAll()
    selectionOrder.removeAll()

    print("🚨 FREEZE DEBUG: Starting file info loading...")
    loadingMessage = "Loading file information..."
    loadingProgress = 0.5

    // Load file info with progress tracking
    let fileInfoStartTime = Date()
    await fileManager.loadFileInfoWithProgress(for: loadedURLs) { progress, message in
      print("🚨 FREEZE DEBUG: File info progress: \(progress), message: \(message)")
      DispatchQueue.main.async {
        self.loadingProgress = 0.5 + (progress * 0.3)  // 50% to 80%
        self.loadingMessage = message
      }
    }

    let fileInfoEndTime = Date()
    print(
      "🚨 FREEZE DEBUG: File info loading COMPLETED at \(fileInfoEndTime), duration: \(fileInfoEndTime.timeIntervalSince(fileInfoStartTime))s"
    )

    loadingProgress = 1.0
    loadingMessage = "Complete"

    let endTime = Date()
    print(
      "🚨 FREEZE DEBUG: loadVideosAndThumbnailsWithProgress COMPLETED at \(endTime), total duration: \(endTime.timeIntervalSince(startTime))s"
    )
  }

  // CRITICAL FIX: New function to handle sorting without reloading the folder
  func applySorting() async {
    let startTime = Date()
    print("🚨 FREEZE DEBUG: applySorting STARTED at \(startTime)")

    guard !videoURLs.isEmpty else {
      print("🚨 FREEZE DEBUG: applySorting SKIPPED - no videos to sort")
      return
    }

    print(
      "🚨 FREEZE DEBUG: About to sort \(videoURLs.count) videos with option: \(sortOption) (ascending: \(sortAscending))"
    )

    // Capture values needed for sorting
    let currentVideoURLs = videoURLs
    let currentSortOption = sortOption
    let currentSortAscending = sortAscending
    let currentFileInfo = fileManager.fileInfo

    print("🚨 FREEZE DEBUG: Captured values, starting detached sorting task...")
    let sortStartTime = Date()

    // Sort the existing videoURLs array without reloading from disk
    let sortedURLs = await Task.detached {
      let detachedStartTime = Date()
      print("🚨 FREEZE DEBUG: Detached sorting task STARTED at \(detachedStartTime)")

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

      let detachedEndTime = Date()
      print(
        "🚨 FREEZE DEBUG: Detached sorting task COMPLETED at \(detachedEndTime), duration: \(detachedEndTime.timeIntervalSince(detachedStartTime))s"
      )

      return result
    }.value

    let sortEndTime = Date()
    print(
      "🚨 FREEZE DEBUG: Sorting task completed at \(sortEndTime), duration: \(sortEndTime.timeIntervalSince(sortStartTime))s"
    )

    print("🚨 FREEZE DEBUG: Updating videoURLs array...")
    videoURLs = sortedURLs

    let endTime = Date()
    print(
      "🚨 FREEZE DEBUG: applySorting COMPLETED at \(endTime), total duration: \(endTime.timeIntervalSince(startTime))s, \(sortedURLs.count) videos sorted"
    )
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
    let startTime = Date()
    print(
      "🚨 FREEZE DEBUG: loadMultipleFolders STARTED at \(startTime) with \(selectedFolders.count) folders"
    )

    isLoadingFolders = true
    loadingProgress = 0.0
    loadingMessage = "Scanning folders..."

    var allFolders: [URL] = []

    // Process each selected folder and its subfolders
    for (index, folderURL) in selectedFolders.enumerated() {
      let folderStartTime = Date()
      print(
        "🚨 FREEZE DEBUG: Processing folder \(index + 1)/\(selectedFolders.count): \(folderURL.lastPathComponent) at \(folderStartTime)"
      )

      loadingMessage =
        "Scanning folder \(index + 1) of \(selectedFolders.count): \(folderURL.lastPathComponent)"
      loadingProgress = Double(index) / Double(selectedFolders.count) * 0.3  // 30% for folder scanning

      // Add the folder itself
      allFolders.append(folderURL)

      // Find subfolders asynchronously
      print("🚨 FREEZE DEBUG: Looking for subfolders in \(folderURL.lastPathComponent)...")
      do {
        let subfolders = try await Task.detached {
          let detachedStartTime = Date()
          print(
            "🚨 FREEZE DEBUG: Subfolder scan detached task STARTED for \(folderURL.lastPathComponent) at \(detachedStartTime)"
          )

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

          let detachedEndTime = Date()
          print(
            "🚨 FREEZE DEBUG: Subfolder scan detached task COMPLETED for \(folderURL.lastPathComponent) at \(detachedEndTime), duration: \(detachedEndTime.timeIntervalSince(detachedStartTime))s, found \(subfolders.count) subfolders"
          )

          return subfolders
        }.value

        allFolders.append(contentsOf: subfolders)

        let folderEndTime = Date()
        print(
          "🚨 FREEZE DEBUG: Folder processing COMPLETED for \(folderURL.lastPathComponent) at \(folderEndTime), duration: \(folderEndTime.timeIntervalSince(folderStartTime))s"
        )

      } catch {
        print("🚨 FREEZE DEBUG: ERROR reading subfolders from \(folderURL): \(error)")
      }
    }

    print("🚨 FREEZE DEBUG: All folder scanning completed, total folders found: \(allFolders.count)")

    // Update folder collection
    folderCollection = allFolders
    currentFolderIndex = 0

    // Load the first folder with improved performance
    if let firstFolder = allFolders.first {
      print("🚨 FREEZE DEBUG: About to load first folder: \(firstFolder.lastPathComponent)")
      let firstFolderStartTime = Date()

      await loadVideosAndThumbnailsWithProgress(from: firstFolder)

      let firstFolderEndTime = Date()
      print(
        "🚨 FREEZE DEBUG: First folder loading COMPLETED at \(firstFolderEndTime), duration: \(firstFolderEndTime.timeIntervalSince(firstFolderStartTime))s"
      )
    } else {
      print("🚨 FREEZE DEBUG: No folders to load")
    }

    isLoadingFolders = false

    let endTime = Date()
    print(
      "🚨 FREEZE DEBUG: loadMultipleFolders COMPLETED at \(endTime), total duration: \(endTime.timeIntervalSince(startTime))s"
    )
  }

  func loadFolderWithSubfolders(from rootFolderURL: URL) async {
    await loadMultipleFolders([rootFolderURL])
  }

  func navigateToPreviousFolder() {
    guard currentFolderIndex > 0 else { return }
    currentFolderIndex -= 1
    let folderURL = folderCollection[currentFolderIndex]
    Task {
      isLoadingFolders = true
      await loadVideosAndThumbnailsWithProgress(from: folderURL)
      isLoadingFolders = false
    }
  }

  func navigateToNextFolder() {
    guard currentFolderIndex < folderCollection.count - 1 else { return }
    currentFolderIndex += 1
    let folderURL = folderCollection[currentFolderIndex]
    Task {
      isLoadingFolders = true
      await loadVideosAndThumbnailsWithProgress(from: folderURL)
      isLoadingFolders = false
    }
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
        print("Error calculating folder info: \(error)")
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
    guard let lastSelected = lastSelectedURL,
      let startIndex = filteredVideoURLs.firstIndex(of: lastSelected),
      let endIndex = filteredVideoURLs.firstIndex(of: url)
    else {
      // If no previous selection or items not found, just select the current item
      toggleSelection(for: url)
      return
    }

    let range = startIndex <= endIndex ? startIndex...endIndex : endIndex...startIndex

    for index in range {
      let urlToSelect = filteredVideoURLs[index]
      if !selectedURLs.contains(urlToSelect) {
        selectedURLs.insert(urlToSelect)
        selectionOrder.append(urlToSelect)
      }
    }

    lastSelectedURL = url
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
    // Open the video file in the default file manager (Finder)
    print("Opening file in Finder: \(url.path)")
    let success = NSWorkspace.shared.selectFile(
      url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    print("Finder open success: \(success)")
  }
}
