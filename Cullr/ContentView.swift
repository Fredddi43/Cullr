// ContentView.swift
// Ultra-lean main view using centralized state management

import AVFoundation
import AppKit
import SwiftUI

/// Main application content view - optimized for performance and modularity
struct ContentView: View {
  @StateObject private var appState = AppState()
  @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220
  @FocusState private var hotkeyFieldFocused: Bool

  var body: some View {
    ZStack {
      mainContent

      // Non-blocking progress indicator
      if appState.fileManager.isLoading && appState.fileManager.thumbnailsToLoad > 0 {
        VStack {
          Spacer()
          HStack {
            Spacer()
            VStack(spacing: 8) {
              ProgressView(
                value: Double(appState.fileManager.thumbnailsLoaded),
                total: Double(appState.fileManager.thumbnailsToLoad)
              )
              .frame(width: 200)
              Text(
                "Loading file info: \(appState.fileManager.thumbnailsLoaded)/\(appState.fileManager.thumbnailsToLoad)"
              )
              .font(.caption)
              .foregroundColor(.secondary)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
          }
        }
      }
    }
    .onAppear {
      appState.setupHotkeyMonitoring()
    }
    .alert(isPresented: $appState.showAlert) {
      createAlert()
    }
  }

  // MARK: - Main Content

  @ViewBuilder
  private var mainContent: some View {
    if appState.folderURL == nil {
      welcomeView
    } else {
      switch appState.playbackMode {
      case .folderView:
        folderView
      case .batchList:
        batchListView
      case .single:
        singleVideoView
      case .sideBySide:
        sideBySideView
      }
    }
  }

  // MARK: - Welcome View

  private var welcomeView: some View {
    VStack(spacing: 24) {
      Image(systemName: "folder.badge.plus")
        .font(.system(size: 64))
        .foregroundColor(.accentColor)

      Text("Select a Folder")
        .font(.largeTitle)
        .fontWeight(.bold)

      Text("Choose a folder containing video files to get started")
        .font(.body)
        .foregroundColor(.secondary)

      Button("Select Folder") {
        selectFolder()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Folder View

  private var folderView: some View {
    VStack(spacing: 0) {
      SettingsBar(
        folderURL: appState.folderURL,
        playbackType: appState.playbackType,
        tempNumberOfClips: appState.numberOfClips,
        tempClipLength: appState.clipLength,
        speedOption: appState.speedOption,
        deleteHotkey: appState.deleteHotkey,
        keepHotkey: appState.keepHotkey,
        isMuted: appState.isMuted,
        totalFilesText: appState.totalFilesText,
        totalSizeText: appState.totalSizeText,
        isTextFieldDisabled: false,
        hotkeyFieldFocused: $hotkeyFieldFocused,
        playbackMode: appState.playbackMode,
        onSelectFolder: selectFolder,
        onPlaybackTypeChange: { appState.playbackType = $0 },
        onNumberOfClipsChange: { appState.numberOfClips = $0 },
        onClipLengthChange: { appState.clipLength = $0 },
        onSpeedOptionChange: { appState.speedOption = $0 },
        onDeleteHotkeyChange: { appState.deleteHotkey = $0 },
        onKeepHotkeyChange: { appState.keepHotkey = $0 },
        onMuteToggle: { appState.isMuted.toggle() },
        onGoAction: {
          Task {
            if let folder = appState.folderURL {
              await appState.loadVideosAndThumbnails(from: folder)
            }
          }
        },
        onPlaybackModeChange: { appState.playbackMode = $0 }
      )

      Divider()

      FilterControls(
        filterSize: $appState.filterSize,
        filterLength: $appState.filterLength,
        filterResolution: $appState.filterResolution,
        filterFileType: $appState.filterFileType
      )
      .padding(.horizontal)

      Divider()

      folderVideoGrid

      if !appState.selectedURLs.isEmpty {
        Divider()
        folderSelectionControls
      }
    }
  }

  private var folderVideoGrid: some View {
    ScrollView {
      LazyVGrid(columns: gridColumns, spacing: 16) {
        ForEach(appState.filteredVideoURLs, id: \.self) { url in
          folderVideoCard(url: url)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
    }
  }

  private var gridColumns: [GridItem] {
    let itemWidth = playerPreviewSize * 0.545
    let spacing: CGFloat = 16

    // Use a single adaptive column that will automatically create multiple columns
    // based on available space and item size
    return [
      GridItem(.adaptive(minimum: itemWidth, maximum: itemWidth), spacing: spacing)
    ]
  }

  private func folderVideoCard(url: URL) -> some View {
    VStack(spacing: 8) {
      ZStack {
        if appState.playbackType == .speed {
          FolderSpeedPreview(
            url: url,
            isMuted: appState.isMuted,
            speedOption: appState.speedOption,
            forcePlay: true
          )
        } else {
          FolderHoverLoopPreview(
            url: url,
            isMuted: appState.isMuted,
            forcePlay: true
          )
        }
      }
      .frame(width: playerPreviewSize * 0.545, height: playerPreviewSize * 0.309)
      .cornerRadius(12)
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(
            appState.selectedURLs.contains(url) ? Color.accentColor : Color.clear, lineWidth: 3)
      )

      VStack(alignment: .leading, spacing: 4) {
        Text(url.lastPathComponent)
          .font(.caption)
          .lineLimit(2)
          .truncationMode(.middle)

        if let info = appState.fileManager.fileInfo[url] {
          Text("\(info.size) • \(info.duration)")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }
      .frame(width: playerPreviewSize * 0.545, alignment: .leading)
    }
    .onTapGesture {
      appState.toggleSelection(for: url)
    }
    .background(appState.selectedURLs.contains(url) ? Color.accentColor.opacity(0.1) : Color.clear)
    .cornerRadius(12)
  }

  private var folderSelectionControls: some View {
    HStack {
      Button("Deselect All") {
        appState.deselectAll()
      }

      Spacer()

      Text("\(appState.selectedURLs.count) selected")
        .font(.caption)

      Spacer()

      Button("Delete Selected") {
        appState.deleteSelectedVideos()
      }

      Button("Preview Selected") {
        let urlsArray = appState.selectionOrder.filter { appState.selectedURLs.contains($0) }
        if !urlsArray.isEmpty {
          QuickLookPreviewCoordinator.shared.preview(urls: urlsArray)
        }
      }
    }
    .padding()
  }

  // MARK: - Batch List View

  private var batchListView: some View {
    VStack(spacing: 0) {
      // Main settings bar
      SettingsBar(
        folderURL: appState.folderURL,
        playbackType: appState.playbackType,
        tempNumberOfClips: appState.numberOfClips,
        tempClipLength: appState.clipLength,
        speedOption: appState.speedOption,
        deleteHotkey: appState.deleteHotkey,
        keepHotkey: appState.keepHotkey,
        isMuted: appState.isMuted,
        totalFilesText: appState.totalFilesText,
        totalSizeText: appState.totalSizeText,
        isTextFieldDisabled: false,
        hotkeyFieldFocused: $hotkeyFieldFocused,
        playbackMode: appState.playbackMode,
        onSelectFolder: selectFolder,
        onPlaybackTypeChange: { appState.playbackType = $0 },
        onNumberOfClipsChange: { appState.numberOfClips = $0 },
        onClipLengthChange: { appState.clipLength = $0 },
        onSpeedOptionChange: { appState.speedOption = $0 },
        onDeleteHotkeyChange: { appState.deleteHotkey = $0 },
        onKeepHotkeyChange: { appState.keepHotkey = $0 },
        onMuteToggle: { appState.isMuted.toggle() },
        onGoAction: {
          Task {
            if let folder = appState.folderURL {
              await appState.loadVideosAndThumbnails(from: folder)
            }
          }
        },
        onPlaybackModeChange: { appState.playbackMode = $0 }
      )

      Divider()

      // Filter controls
      VStack(spacing: 8) {
        FilterControls(
          filterSize: $appState.filterSize,
          filterLength: $appState.filterLength,
          filterResolution: $appState.filterResolution,
          filterFileType: $appState.filterFileType
        )
        .padding(.horizontal)

        HStack {
          Text("\(appState.filteredVideoURLs.count) videos")
            .font(.caption)
            .foregroundColor(.secondary)

          Spacer()

          if !appState.selectedURLs.isEmpty {
            Text("\(appState.selectedURLs.count) selected")
              .font(.caption)
              .foregroundColor(.accentColor)
          }
        }
        .padding(.horizontal)
      }
      .padding(.vertical, 8)

      Divider()

      // Video list
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(Array(appState.filteredVideoURLs.enumerated()), id: \.element) { index, url in
            BatchListRowView(
              url: url,
              times: getClipTimes(for: url, count: appState.numberOfClips),
              staticThumbnails: [:],  // Will be loaded by the component
              isMuted: appState.isMuted,
              playbackType: appState.playbackType,
              speedOption: appState.speedOption,
              isSelected: Binding(
                get: { appState.selectedURLs.contains(url) },
                set: { _ in appState.toggleSelection(for: url) }
              ),
              fileInfo: appState.fileManager.fileInfo[url],
              isRowHovered: appState.hoveredBatchRow == url,
              onHoverChanged: { hovering in
                appState.hoveredBatchRow = hovering ? url : nil
              }
            )

            if index < appState.filteredVideoURLs.count - 1 {
              Divider()
                .padding(.horizontal, 16)
            }
          }
        }
        .padding(.vertical, 8)
      }

      // Bottom controls
      if !appState.selectedURLs.isEmpty {
        Divider()
        batchSelectionControls
      }
    }
  }

  private var batchSelectionControls: some View {
    HStack {
      Button("Select All") {
        appState.selectAll()
      }

      Button("Deselect All") {
        appState.deselectAll()
      }

      Spacer()

      Text("\(appState.selectedURLs.count) selected")
        .font(.caption)

      Spacer()

      Button("Delete Selected") {
        appState.deleteSelectedVideos()
      }

      Button("Preview Selected") {
        let urlsArray = appState.selectionOrder.filter { appState.selectedURLs.contains($0) }
        if !urlsArray.isEmpty {
          QuickLookPreviewCoordinator.shared.preview(urls: urlsArray)
        }
      }
    }
    .padding()
  }

  // MARK: - Single Video View

  private var singleVideoView: some View {
    VStack(spacing: 0) {
      // Main settings bar
      SettingsBar(
        folderURL: appState.folderURL,
        playbackType: appState.playbackType,
        tempNumberOfClips: appState.numberOfClips,
        tempClipLength: appState.clipLength,
        speedOption: appState.speedOption,
        deleteHotkey: appState.deleteHotkey,
        keepHotkey: appState.keepHotkey,
        isMuted: appState.isMuted,
        totalFilesText: appState.totalFilesText,
        totalSizeText: appState.totalSizeText,
        isTextFieldDisabled: false,
        hotkeyFieldFocused: $hotkeyFieldFocused,
        playbackMode: appState.playbackMode,
        onSelectFolder: selectFolder,
        onPlaybackTypeChange: { appState.playbackType = $0 },
        onNumberOfClipsChange: { appState.numberOfClips = $0 },
        onClipLengthChange: { appState.clipLength = $0 },
        onSpeedOptionChange: { appState.speedOption = $0 },
        onDeleteHotkeyChange: { appState.deleteHotkey = $0 },
        onKeepHotkeyChange: { appState.keepHotkey = $0 },
        onMuteToggle: { appState.isMuted.toggle() },
        onGoAction: {
          Task {
            if let folder = appState.folderURL {
              await appState.loadVideosAndThumbnails(from: folder)
            }
          }
        },
        onPlaybackModeChange: { appState.playbackMode = $0 }
      )

      Divider()

      // Video player section
      VStack {
        if appState.currentIndex < appState.videoURLs.count {
          let url = appState.videoURLs[appState.currentIndex]

          if appState.playbackType == .speed {
            SpeedPlayer(
              url: url,
              speedOption: $appState.speedOption,
              isMuted: $appState.isMuted
            )
          } else {
            ClipLoopingPlayer(
              url: url,
              numberOfClips: appState.numberOfClips,
              clipLength: appState.clipLength,
              isMuted: $appState.isMuted
            )
          }

          HStack {
            Button("Delete") {
              appState.deleteCurrentVideo()
            }
            .keyboardShortcut(KeyEquivalent(Character(appState.deleteHotkey)), modifiers: [])

            Spacer()

            Text("\(appState.currentIndex + 1) of \(appState.videoURLs.count)")
              .font(.caption)

            Spacer()

            Button("Keep") {
              appState.skipCurrentVideo()
            }
            .keyboardShortcut(KeyEquivalent(Character(appState.keepHotkey)), modifiers: [])
          }
          .padding()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Side by Side View

  private var sideBySideView: some View {
    VStack(spacing: 0) {
      // Main settings bar
      SettingsBar(
        folderURL: appState.folderURL,
        playbackType: appState.playbackType,
        tempNumberOfClips: appState.numberOfClips,
        tempClipLength: appState.clipLength,
        speedOption: appState.speedOption,
        deleteHotkey: appState.deleteHotkey,
        keepHotkey: appState.keepHotkey,
        isMuted: appState.isMuted,
        totalFilesText: appState.totalFilesText,
        totalSizeText: appState.totalSizeText,
        isTextFieldDisabled: false,
        hotkeyFieldFocused: $hotkeyFieldFocused,
        playbackMode: appState.playbackMode,
        onSelectFolder: selectFolder,
        onPlaybackTypeChange: { appState.playbackType = $0 },
        onNumberOfClipsChange: { appState.numberOfClips = $0 },
        onClipLengthChange: { appState.clipLength = $0 },
        onSpeedOptionChange: { appState.speedOption = $0 },
        onDeleteHotkeyChange: { appState.deleteHotkey = $0 },
        onKeepHotkeyChange: { appState.keepHotkey = $0 },
        onMuteToggle: { appState.isMuted.toggle() },
        onGoAction: {
          Task {
            if let folder = appState.folderURL {
              await appState.loadVideosAndThumbnails(from: folder)
            }
          }
        },
        onPlaybackModeChange: { appState.playbackMode = $0 }
      )

      Divider()

      // Video players section
      VStack(spacing: 16) {
        HStack(spacing: 16) {
          // Left video
          if appState.currentIndex < appState.videoURLs.count {
            videoPlayerCard(url: appState.videoURLs[appState.currentIndex], title: "Left")
          }

          // Right video
          if appState.currentIndex + 1 < appState.videoURLs.count {
            videoPlayerCard(url: appState.videoURLs[appState.currentIndex + 1], title: "Right")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // Controls
        HStack {
          Button("Delete Left") {
            appState.deleteCurrentVideo()
          }
          .keyboardShortcut(KeyEquivalent(Character(appState.deleteHotkey)), modifiers: [])

          Button("Delete Right") {
            if appState.currentIndex + 1 < appState.videoURLs.count {
              let url = appState.videoURLs[appState.currentIndex + 1]
              appState.filesPendingDeletion = [url]
              appState.alertType = .fileDelete
              appState.showAlert = true
            }
          }
          .disabled(appState.currentIndex + 1 >= appState.videoURLs.count)

          Spacer()

          Text(
            "\(appState.currentIndex + 1)-\(min(appState.currentIndex + 2, appState.videoURLs.count)) of \(appState.videoURLs.count)"
          )
          .font(.caption)

          Spacer()

          Button("Keep Both") {
            appState.skipCurrentVideo()
            if appState.currentIndex < appState.videoURLs.count {
              appState.skipCurrentVideo()
            }
          }
          .keyboardShortcut(KeyEquivalent(Character(appState.keepHotkey)), modifiers: [])
        }
        .padding()
      }
      .padding(.top, 16)
    }
  }

  private func videoPlayerCard(url: URL, title: String) -> some View {
    VStack {
      if appState.playbackType == .speed {
        SpeedPlayer(
          url: url,
          speedOption: $appState.speedOption,
          isMuted: $appState.isMuted
        )
      } else {
        ClipLoopingPlayer(
          url: url,
          numberOfClips: appState.numberOfClips,
          clipLength: appState.clipLength,
          isMuted: $appState.isMuted
        )
      }

      Text(url.lastPathComponent)
        .font(.caption)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .aspectRatio(16 / 9, contentMode: .fit)
  }

  // MARK: - Actions

  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false

    if panel.runModal() == .OK, let url = panel.url {
      Task {
        await appState.loadVideosAndThumbnails(from: url)
      }
    }
  }

  private func createAlert() -> Alert {
    switch appState.alertType {
    case .fileDelete:
      return Alert(
        title: Text("Confirm Deletion"),
        message: Text(
          "Are you sure you want to delete \(appState.filesPendingDeletion.count) file(s)? This action cannot be undone."
        ),
        primaryButton: .destructive(Text("Delete")) {
          Task {
            await performFileDeletion()
          }
        },
        secondaryButton: .cancel {
          appState.filesPendingDeletion.removeAll()
        }
      )
    case .folderDelete:
      let info = appState.folderDeletionInfo ?? (fileCount: 0, size: "", name: "")
      return Alert(
        title: Text("Delete Folder"),
        message: Text("Delete '\(info.name)' containing \(info.fileCount) files (\(info.size))?"),
        primaryButton: .destructive(Text("Delete")) {
          Task {
            await performFolderDeletion()
          }
        },
        secondaryButton: .cancel {
          appState.folderPendingDeletion = nil
          appState.folderDeletionInfo = nil
        }
      )
    }
  }

  private func performFileDeletion() async {
    for url in appState.filesPendingDeletion {
      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        await MainActor.run {
          appState.videoURLs.removeAll { $0 == url }
          appState.selectedURLs.remove(url)
          appState.selectionOrder.removeAll { $0 == url }
          appState.fileManager.fileInfo.removeValue(forKey: url)
        }
      } catch {
        print("Error deleting file: \(error)")
      }
    }
    appState.filesPendingDeletion.removeAll()
  }

  private func performFolderDeletion() async {
    guard let folderURL = appState.folderPendingDeletion else { return }

    do {
      try FileManager.default.trashItem(at: folderURL, resultingItemURL: nil)
      await MainActor.run {
        appState.folderCollection.removeAll { $0 == folderURL }
        if appState.currentFolderIndex >= appState.folderCollection.count {
          appState.currentFolderIndex = max(0, appState.folderCollection.count - 1)
        }
      }
    } catch {
      print("Error deleting folder: \(error)")
    }

    appState.folderPendingDeletion = nil
    appState.folderDeletionInfo = nil
  }
}
