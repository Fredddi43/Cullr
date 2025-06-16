// ContentView.swift

import AVFoundation
import AppKit
import SwiftUI

/// Main application content view - now modular and clean
struct ContentView: View {
  // MARK: - Basic State
  @State private var videoURLs: [URL] = []
  @State private var folderURL: URL? = nil
  @State private var folderAccessing: Bool = false
  @State private var isPrepared: Bool = false
  @State private var currentIndex: Int = 0
  @State private var player: AVPlayer? = nil
  @State private var sortOption: SortOption = .name
  @State private var sortAscending: Bool = true

  // MARK: - Filters
  @State private var filterSize: FilterSizeOption = .all
  @State private var filterLength: FilterLengthOption = .all
  @State private var filterResolution: FilterResolutionOption = .all
  @State private var filterFileType: FilterFileTypeOption = .all
  @State private var isTextFieldDisabled: Bool = true
  @FocusState private var hotkeyFieldFocused: Bool
  @State private var deleteHotkey: String = "d"
  @State private var keepHotkey: String = "k"
  @State private var isMuted: Bool = true
  @State private var playbackMode: PlaybackMode = .folderView
  @State private var playbackType: PlaybackType = .clips
  @State private var speedOption: SpeedOption = .x2

  // MARK: - Selections
  @State private var batchSelection: [Bool] = []
  @State private var selectedURLs: Set<URL> = []
  @State private var selectionOrder: [URL] = []
  @State private var staticThumbnails: [String: Image] = [:]

  // MARK: - Media Info
  @State private var totalFilesText: String = ""
  @State private var totalSizeText: String = ""
  @State private var fileInfo: [URL: FileInfo] = [:]

  // MARK: - State
  @State private var isLoadingThumbnails: Bool = false
  @State private var thumbnailsToLoad: Int = 0
  @State private var thumbnailsLoaded: Int = 0
  @State private var hoveredBatchRow: URL? = nil
  @State private var lastSelectedItem: URL? = nil

  // MARK: - Configuration
  @State private var numberOfClips: Int = 5
  @State private var clipLength: Int = 3
  @State private var tempNumberOfClips: Int = 5
  @State private var tempClipLength: Int = 3

  // MARK: - Deletion States
  @State private var showDeleteConfirmation = false
  @State private var filesPendingDeletion: [URL] = []
  @State private var showFolderDeleteConfirmation = false
  @State private var folderPendingDeletion: URL? = nil
  @State private var folderDeletionInfo: (fileCount: Int, size: String, name: String)? = nil
  @State private var showAlert = false
  @State private var alertType: AlertType = .fileDelete

  // MARK: - Folder Collection
  @State private var folderCollection: [URL] = []
  @State private var currentFolderIndex: Int = 0
  @State private var viewReloadID = UUID()

  // MARK: - Player State
  @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220

  // MARK: - Global Managers
  @StateObject private var hotkeyMonitor = GlobalHotkeyMonitor()
  private let thumbnailCache = ThumbnailCache.shared

  // MARK: - Computed Properties
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
        if let duration = durationInSeconds(from: info.duration) {
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

  private var isFolderCollectionMode: Bool { folderCollection.count > 1 }

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
          configureWindowTransparency(folderName: folderURL?.lastPathComponent)
          setupHotkeyMonitoring()

          // Re-enable text fields after a short delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isTextFieldDisabled = false
          }
        }
        .onDisappear {
          hotkeyMonitor.stopMonitoring()
        }

      mainContentView

      // Loading overlay
      if isLoadingThumbnails {
        LoadingOverlay(
          thumbnailsLoaded: thumbnailsLoaded,
          thumbnailsToLoad: thumbnailsToLoad
        )
      }

      // Folder Collection Bottom Bar
      if isFolderCollectionMode {
        FolderCollectionBottomBar(
          folderURL: folderURL,
          currentFolderIndex: currentFolderIndex,
          folderCollectionCount: folderCollection.count,
          onPreviousFolder: previousFolder,
          onNextFolder: nextFolder,
          onDeleteFolder: {
            Task {
              await prepareFolderDeletion()
            }
          }
        )
      }
    }
    .frame(minWidth: 1200, minHeight: 800)
  }

  // MARK: - Main Content View (Extracted to avoid compiler complexity)
  private var mainContentView: some View {
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
          singleClipView
        case .sideBySide:
          sideBySideClipsView
        case .batchList:
          batchListView
        case .folderView:
          folderView
        }
      }
    }
    .id(viewReloadID)
    .alert(isPresented: $showAlert) {
      createAlertForType()
    }
  }

  // MARK: - Settings Bar
  private var settingsBar: some View {
    SettingsBar(
      folderURL: folderURL,
      playbackType: playbackType,
      tempNumberOfClips: tempNumberOfClips,
      tempClipLength: tempClipLength,
      speedOption: speedOption,
      deleteHotkey: deleteHotkey,
      keepHotkey: keepHotkey,
      isMuted: isMuted,
      totalFilesText: totalFilesText,
      totalSizeText: totalSizeText,
      isTextFieldDisabled: isTextFieldDisabled,
      hotkeyFieldFocused: $hotkeyFieldFocused,
      playbackMode: playbackMode,
      onSelectFolder: selectFolder,
      onPlaybackTypeChange: { playbackType = $0 },
      onNumberOfClipsChange: { tempNumberOfClips = $0 },
      onClipLengthChange: { tempClipLength = $0 },
      onSpeedOptionChange: { speedOption = $0 },
      onDeleteHotkeyChange: { deleteHotkey = $0 },
      onKeepHotkeyChange: { keepHotkey = $0 },
      onMuteToggle: { isMuted.toggle() },
      onGoAction: {
        Task {
          numberOfClips = tempNumberOfClips
          clipLength = tempClipLength
          if let folder = folderURL {
            await loadVideosAndThumbnails(from: folder)
            viewReloadID = UUID()
          }
        }
      },
      onPlaybackModeChange: { newMode in
        playbackMode = newMode
        if newMode != .folderView {
          Task {
            await initializeForCurrentMode()
          }
        } else {
          syncBatchSelectionFromSelectedURLs()
        }
      }
    )
  }

  // MARK: - View Modes
  private var singleClipView: some View {
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
            SpeedPlayer(
              url: url,
              speedOption: $speedOption,
              isMuted: $isMuted
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
          } else {
            ClipLoopingPlayer(
              url: url,
              numberOfClips: numberOfClips,
              clipLength: clipLength,
              isMuted: $isMuted
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
          }
        }
      }

      // Navigation controls
      HStack {
        Button("Delete") {
          deleteCurrentVideo()
        }
        .keyboardShortcut(KeyEquivalent(Character(deleteHotkey)), modifiers: [])

        Spacer()

        Text("\(currentIndex + 1) of \(videoURLs.count)")
          .font(.caption)

        Spacer()

        Button("Keep") {
          skipCurrentVideo()
        }
        .keyboardShortcut(KeyEquivalent(Character(keepHotkey)), modifiers: [])
      }
      .padding()
    }
  }

  private var sideBySideClipsView: some View {
    VStack(spacing: 16) {
      HStack(spacing: 16) {
        // Left video
        if currentIndex < videoURLs.count {
          let leftURL = videoURLs[currentIndex]
          VStack {
            if playbackType == .speed {
              SpeedPlayer(
                url: leftURL,
                speedOption: $speedOption,
                isMuted: $isMuted
              )
            } else {
              ClipLoopingPlayer(
                url: leftURL,
                numberOfClips: numberOfClips,
                clipLength: clipLength,
                isMuted: $isMuted
              )
            }
            Text(leftURL.lastPathComponent)
              .font(.caption)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .aspectRatio(16 / 9, contentMode: .fit)
        }

        // Right video
        if currentIndex + 1 < videoURLs.count {
          let rightURL = videoURLs[currentIndex + 1]
          VStack {
            if playbackType == .speed {
              SpeedPlayer(
                url: rightURL,
                speedOption: $speedOption,
                isMuted: $isMuted
              )
            } else {
              ClipLoopingPlayer(
                url: rightURL,
                numberOfClips: numberOfClips,
                clipLength: clipLength,
                isMuted: $isMuted
              )
            }
            Text(rightURL.lastPathComponent)
              .font(.caption)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .aspectRatio(16 / 9, contentMode: .fit)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // Controls
      HStack {
        Button("Delete Left") {
          deleteCurrentVideo()
        }
        .keyboardShortcut(KeyEquivalent(Character(deleteHotkey)), modifiers: [])

        Button("Delete Right") {
          deleteVideo(at: currentIndex + 1)
        }
        .disabled(currentIndex + 1 >= videoURLs.count)

        Spacer()

        Text("\(currentIndex + 1)-\(min(currentIndex + 2, videoURLs.count)) of \(videoURLs.count)")
          .font(.caption)

        Spacer()

        Button("Keep Both") {
          skipCurrentVideo()
          if currentIndex < videoURLs.count {
            skipCurrentVideo()  // Skip the second one too
          }
        }
        .keyboardShortcut(KeyEquivalent(Character(keepHotkey)), modifiers: [])
      }
      .padding()
    }
  }

  private var batchListView: some View {
    VStack(spacing: 0) {
      // Filter controls
      FilterControls(
        filterSize: $filterSize,
        filterLength: $filterLength,
        filterResolution: $filterResolution,
        filterFileType: $filterFileType
      )
      .padding(.horizontal)

      Divider()

      // List of videos
      ScrollView {
        LazyVStack(spacing: 1) {
          ForEach(Array(filteredVideoURLs.enumerated()), id: \.element) { index, url in
            BatchListRowView(
              url: url,
              times: getClipTimes(for: url, count: numberOfClips),
              staticThumbnails: staticThumbnails,
              isMuted: isMuted,
              playbackType: playbackType,
              speedOption: speedOption,
              isSelected: Binding(
                get: { selectedURLs.contains(url) },
                set: { _ in toggleSelection(for: url) }
              ),
              fileInfo: fileInfo[url],
              isRowHovered: hoveredBatchRow == url,
              onHoverChanged: { hovering in
                hoveredBatchRow = hovering ? url : nil
              }
            )
          }
        }
      }

      Divider()

      // Batch actions
      HStack {
        Button("Select All") {
          selectedURLs = Set(filteredVideoURLs)
          syncBatchSelectionFromSelectedURLs()
        }

        Button("Deselect All") {
          selectedURLs.removeAll()
          syncBatchSelectionFromSelectedURLs()
        }

        Spacer()

        Text("\(selectedURLs.count) selected")
          .font(.caption)

        Spacer()

        Button("Delete Selected") {
          deleteSelectedVideos()
        }
        .disabled(selectedURLs.isEmpty)

        Button("Preview Selected") {
          let urlsArray = selectionOrder.filter { selectedURLs.contains($0) }
          if !urlsArray.isEmpty {
            QuickLookPreviewCoordinator.shared.preview(urls: urlsArray)
          }
        }
        .disabled(selectedURLs.isEmpty)
      }
      .padding()
    }
  }

  private var folderView: some View {
    VStack(spacing: 0) {
      folderFilterControls
      folderVideoGrid
      folderSelectionControls
    }
  }

  // MARK: - Folder View Components

  private var folderFilterControls: some View {
    VStack(spacing: 0) {
      // Filter controls
      FilterControls(
        filterSize: $filterSize,
        filterLength: $filterLength,
        filterResolution: $filterResolution,
        filterFileType: $filterFileType
      )
      .padding(.horizontal)

      Divider()

      // Player size slider
      PlayerSizeSlider(compact: false)
        .padding(.horizontal)

      Divider()
    }
  }

  private var folderVideoGrid: some View {
    ScrollView {
      videoGridContent
        .padding()
    }
  }

  private var videoGridContent: some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: 8), count: Int(1200 / (playerPreviewSize + 8))),
      spacing: 8
    ) {
      ForEach(Array(filteredVideoURLs.enumerated()), id: \.element) { (index: Int, url: URL) in
        if playbackType == .speed {
          FolderSpeedPreview(
            url: url,
            isMuted: isMuted,
            speedOption: speedOption
          )
        } else {
          FolderHoverLoopPreview(
            url: url,
            isMuted: isMuted,
            numberOfClips: numberOfClips,
            clipLength: clipLength,
            playbackType: playbackType,
            speedOption: speedOption
          )
        }
      }
    }
  }

  @ViewBuilder
  private var folderSelectionControls: some View {
    if !selectedURLs.isEmpty {
      Divider()

      // Selection controls
      HStack {
        Button("Deselect All") {
          selectedURLs.removeAll()
          selectionOrder.removeAll()
        }

        Spacer()

        Text("\(selectedURLs.count) selected")
          .font(.caption)

        Spacer()

        Button("Delete Selected") {
          deleteSelectedVideos()
        }

        Button("Preview Selected") {
          let urlsArray = selectionOrder.filter { selectedURLs.contains($0) }
          if !urlsArray.isEmpty {
            QuickLookPreviewCoordinator.shared.preview(urls: urlsArray)
          }
        }
      }
      .padding()
    }
  }

  // MARK: - Actions
  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false

    if panel.runModal() == .OK, let url = panel.url {
      folderURL = url
      Task {
        await loadVideosAndThumbnails(from: url)
      }
    }
  }

  private func loadVideosAndThumbnails(from folderURL: URL) async {
    // Load videos
    await loadVideos(from: folderURL)

    // Reset state
    await MainActor.run {
      currentIndex = 0
      selectedURLs.removeAll()
      selectionOrder.removeAll()
      batchSelection = Array(repeating: false, count: videoURLs.count)

      // Update totals
      updateTotalInfo()
    }

    // Load thumbnails in background
    await loadThumbnails()
  }

  private func loadVideos(from folderURL: URL) async {
    do {
      let fileManager = FileManager.default
      let contents = try fileManager.contentsOfDirectory(
        at: folderURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])

      let videos = contents.filter { fileManager.isVideoFile($0) }

      // Sort videos
      let sortedVideos = try await withTimeout(10) {
        return videos.sorted { url1, url2 in
          switch sortOption {
          case .name:
            return sortAscending
              ? url1.lastPathComponent < url2.lastPathComponent
              : url1.lastPathComponent > url2.lastPathComponent
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
          case .duration:
            // For duration sorting, we'd need to load file info first
            return sortAscending
              ? url1.lastPathComponent < url2.lastPathComponent
              : url1.lastPathComponent > url2.lastPathComponent
          case .dateAdded:
            // For date added sorting, use name as fallback
            return sortAscending
              ? url1.lastPathComponent < url2.lastPathComponent
              : url1.lastPathComponent > url2.lastPathComponent
          }
        }
      }

      await MainActor.run {
        videoURLs = sortedVideos
      }
    } catch {
      print("Error loading videos: \(error)")
    }
  }

  private func loadThumbnails() async {
    await MainActor.run {
      isLoadingThumbnails = true
      thumbnailsToLoad = videoURLs.count
      thumbnailsLoaded = 0
    }

    for (index, url) in videoURLs.enumerated() {
      // Load file info
      await loadFileInfo(for: url)

      await MainActor.run {
        thumbnailsLoaded = index + 1
      }
    }

    await MainActor.run {
      isLoadingThumbnails = false
      updateTotalInfo()
    }
  }

  private func loadFileInfo(for url: URL) async {
    do {
      let asset = AVURLAsset(url: url)

      // Load basic properties
      let duration = try await asset.load(.duration)
      let tracks = try await asset.load(.tracks)

      // Get file size
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let fileSize = attributes[.size] as? UInt64 ?? 0

      // Get video track info
      let videoTrack = tracks.first { $0.mediaType == .video }
      var resolution = "Unknown"
      var fps = "Unknown"

      if let track = videoTrack {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)

        // Apply transform to get actual displayed size
        let transformedSize = naturalSize.applying(transform)
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))

        resolution = "\(width)x\(height)"
        fps = String(format: "%.1f", nominalFrameRate)
      }

      let info = FileInfo(
        size: formatFileSize(bytes: fileSize),
        duration: formatDuration(duration.seconds),
        resolution: resolution,
        fps: fps
      )

      await MainActor.run {
        fileInfo[url] = info
      }
    } catch {
      let info = FileInfo(
        size: "Unknown",
        duration: "Unknown",
        resolution: "Unknown",
        fps: "Unknown"
      )

      await MainActor.run {
        fileInfo[url] = info
      }
    }
  }

  private func updateTotalInfo() {
    let totalFiles = videoURLs.count
    let totalSize = videoURLs.compactMap { url in
      try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64
    }.reduce(0, +)

    totalFilesText = "\(totalFiles) files"
    totalSizeText = formatFileSize(bytes: totalSize)
  }

  private func setupHotkeyMonitoring() {
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

  private func handleGlobalSpacebar() {
    // Toggle playback or handle spacebar action
    print("Global spacebar pressed")
  }

  private func deleteCurrentVideo() {
    guard currentIndex < videoURLs.count else { return }
    let url = videoURLs[currentIndex]
    filesPendingDeletion = [url]
    alertType = .fileDelete
    showAlert = true
  }

  private func deleteVideo(at index: Int) {
    guard index < videoURLs.count else { return }
    let url = videoURLs[index]
    filesPendingDeletion = [url]
    alertType = .fileDelete
    showAlert = true
  }

  private func deleteSelectedVideos() {
    let selectedArray = Array(selectedURLs)
    filesPendingDeletion = selectedArray
    alertType = .fileDelete
    showAlert = true
  }

  private func skipCurrentVideo() {
    guard currentIndex < videoURLs.count else { return }
    currentIndex = min(currentIndex + 1, videoURLs.count - 1)
  }

  private func toggleSelection(for url: URL) {
    if selectedURLs.contains(url) {
      selectedURLs.remove(url)
      selectionOrder.removeAll { $0 == url }
    } else {
      selectedURLs.insert(url)
      selectionOrder.append(url)
    }
    syncBatchSelectionFromSelectedURLs()
  }

  private func syncBatchSelectionFromSelectedURLs() {
    batchSelection = videoURLs.map { selectedURLs.contains($0) }
  }

  private func initializeForCurrentMode() async {
    // Initialize any mode-specific setup
    await MainActor.run {
      currentIndex = 0
    }
  }

  private func createAlertForType() -> Alert {
    switch alertType {
    case .fileDelete:
      return Alert(
        title: Text("Confirm Deletion"),
        message: Text(
          "Are you sure you want to delete \(filesPendingDeletion.count) file(s)? This action cannot be undone."
        ),
        primaryButton: .destructive(Text("Delete")) {
          Task {
            await performFileDeletion()
          }
        },
        secondaryButton: .cancel {
          filesPendingDeletion.removeAll()
        }
      )
    case .folderDelete:
      let info = folderDeletionInfo ?? (fileCount: 0, size: "", name: "")
      return Alert(
        title: Text("Delete Folder"),
        message: Text("Delete '\(info.name)' containing \(info.fileCount) files (\(info.size))?"),
        primaryButton: .destructive(Text("Delete")) {
          Task {
            await performFolderDeletion()
          }
        },
        secondaryButton: .cancel {
          folderPendingDeletion = nil
          folderDeletionInfo = nil
        }
      )
    }
  }

  private func performFileDeletion() async {
    for url in filesPendingDeletion {
      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        await MainActor.run {
          videoURLs.removeAll { $0 == url }
          selectedURLs.remove(url)
          selectionOrder.removeAll { $0 == url }
          fileInfo.removeValue(forKey: url)
        }
      } catch {
        print("Error deleting file: \(error)")
      }
    }

    await MainActor.run {
      filesPendingDeletion.removeAll()
      batchSelection = Array(repeating: false, count: videoURLs.count)
      if currentIndex >= videoURLs.count && !videoURLs.isEmpty {
        currentIndex = videoURLs.count - 1
      }
      updateTotalInfo()
    }
  }

  private func prepareFolderDeletion() async {
    guard let folder = folderURL else { return }

    do {
      let contents = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.fileSizeKey])
      let totalSize = contents.compactMap { url in
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
      }.reduce(0, +)

      await MainActor.run {
        folderPendingDeletion = folder
        folderDeletionInfo = (
          fileCount: contents.count,
          size: formatFileSize(bytes: UInt64(totalSize)),
          name: folder.lastPathComponent
        )
        alertType = .folderDelete
        showAlert = true
      }
    } catch {
      print("Error preparing folder deletion: \(error)")
    }
  }

  private func performFolderDeletion() async {
    guard let folder = folderPendingDeletion else { return }

    do {
      try FileManager.default.trashItem(at: folder, resultingItemURL: nil)

      await MainActor.run {
        folderPendingDeletion = nil
        folderDeletionInfo = nil

        // Move to next folder if in collection mode
        if isFolderCollectionMode {
          nextFolder()
        } else {
          // Clear current folder
          folderURL = nil
          videoURLs.removeAll()
          fileInfo.removeAll()
          selectedURLs.removeAll()
          selectionOrder.removeAll()
        }
      }
    } catch {
      print("Error deleting folder: \(error)")
    }
  }

  private func previousFolder() {
    guard isFolderCollectionMode && currentFolderIndex > 0 else { return }
    currentFolderIndex -= 1
    folderURL = folderCollection[currentFolderIndex]
    Task {
      await loadVideosAndThumbnails(from: folderURL!)
    }
  }

  private func nextFolder() {
    guard isFolderCollectionMode && currentFolderIndex < folderCollection.count - 1 else { return }
    currentFolderIndex += 1
    folderURL = folderCollection[currentFolderIndex]
    Task {
      await loadVideosAndThumbnails(from: folderURL!)
    }
  }
}
