import AVFoundation
import AppKit
import SwiftUI

// MARK: - Batch List Components

/// Row view for batch list mode showing video clips and metadata
struct BatchListRowView: View {
  let url: URL
  let times: [Double]
  let staticThumbnails: [String: Image]
  let isMuted: Bool
  let playbackType: PlaybackType
  let speedOption: SpeedOption
  @Binding var isSelected: Bool
  let fileInfo: FileInfo?
  let isRowHovered: Bool
  let onHoverChanged: (Bool) -> Void
  let onDoubleClick: () -> Void
  let onShiftClick: () -> Void

  @State private var clipThumbnails: [Int: Image] = [:]
  @State private var thumbnailRequestIds: [Int] = []
  @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220
  @EnvironmentObject private var appState: AppState

  var body: some View {
    HStack(spacing: 12) {
      previewSection
      fileInfoSection
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(backgroundView)
    .contentShape(Rectangle())
    .onHover { hovering in
      onHoverChanged(hovering)
    }
    .onTapGesture(count: 2) {
      onDoubleClick()
    }
    .simultaneousGesture(
      TapGesture()
        .modifiers(.shift)
        .onEnded {
          onShiftClick()
        }
    )
    .onTapGesture {
      isSelected.toggle()
    }
    .onAppear {
      // SIMPLIFIED FIX: ONLY use pre-loaded thumbnails from AppState
      // Don't generate thumbnails in ViewComponents - let AppState handle it
      loadPreloadedThumbnails()
    }
    .onChange(of: appState.folderThumbnails) { _, _ in
      // Update when new thumbnails arrive
      loadPreloadedThumbnails()
    }
  }

  @ViewBuilder
  private var previewSection: some View {
    if playbackType == .clips && times.count > 1 {
      clipsPreviewView
    } else {
      singlePreviewView
    }
  }

  @ViewBuilder
  private var clipsPreviewView: some View {
    let clipWidth = playerPreviewSize * 0.545
    let clipHeight = playerPreviewSize * 0.309

    HStack(spacing: 2) {
      ForEach(Array(times.enumerated()), id: \.offset) { index, time in
        clipThumbnailView(index: index, width: clipWidth, height: clipHeight)
      }
    }
    .frame(
      width: clipWidth * CGFloat(times.count) + CGFloat((times.count - 1) * 2),
      height: clipHeight)
  }

  @ViewBuilder
  private var singlePreviewView: some View {
    let singleWidth = playerPreviewSize * 0.545
    let singleHeight = playerPreviewSize * 0.309

    ZStack {
      // CRITICAL FIX: Use static thumbnail by default, only show video player when actually hovered
      if let thumbnail = clipThumbnails[0] {
        thumbnail
          .resizable()
          .aspectRatio(16 / 9, contentMode: .fill)
          .frame(width: singleWidth, height: singleHeight)
          .clipped()
          .cornerRadius(8)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .aspectRatio(16 / 9, contentMode: .fill)
          .frame(width: singleWidth, height: singleHeight)
          .cornerRadius(8)
      }

      // PERFORMANCE FIX: Only show video player when this specific row is hovered AND there's no other video playing
      if isRowHovered && appState.shouldPlayVideo(url, hoveredURL: appState.hoveredVideoURL)
        && appState.hoveredVideoURL == url
      {
        if playbackType == .speed {
          FolderSpeedPreview(
            url: url,
            isMuted: isMuted,
            speedOption: speedOption,
            forcePlay: true,
            thumbnail: clipThumbnails[0]
          )
          .frame(width: singleWidth, height: singleHeight)
          .clipped()
          .cornerRadius(8)
        } else {
          FolderHoverLoopPreview(
            url: url,
            isMuted: isMuted,
            forcePlay: true,
            thumbnail: clipThumbnails[0]
          )
          .frame(width: singleWidth, height: singleHeight)
          .clipped()
          .cornerRadius(8)
        }
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
    )
  }

  @ViewBuilder
  private func clipThumbnailView(index: Int, width: CGFloat, height: CGFloat) -> some View {
    ZStack {
      // CRITICAL FIX: Use static thumbnail by default, only show video player when actually hovered
      if let thumbnail = clipThumbnails[index] {
        thumbnail
          .resizable()
          .aspectRatio(16 / 9, contentMode: .fill)
          .frame(width: width, height: height)
          .clipped()
          .cornerRadius(6)
      } else {
        Rectangle()
          .fill(Color.gray.opacity(0.3))
          .aspectRatio(16 / 9, contentMode: .fill)
          .frame(width: width, height: height)
          .cornerRadius(6)
      }

      // PERFORMANCE FIX: Only show video player when this specific row is hovered AND there's no other video playing
      if isRowHovered && appState.shouldPlayVideo(url, hoveredURL: appState.hoveredVideoURL)
        && appState.hoveredVideoURL == url
      {
        if playbackType == .speed {
          FolderSpeedPreview(
            url: url,
            isMuted: isMuted,
            speedOption: speedOption,
            forcePlay: true,
            thumbnail: clipThumbnails[index]
          )
          .frame(width: width, height: height)
          .clipped()
          .cornerRadius(6)
        } else {
          FolderHoverLoopPreview(
            url: url,
            isMuted: isMuted,
            forcePlay: true,
            thumbnail: clipThumbnails[index]
          )
          .frame(width: width, height: height)
          .clipped()
          .cornerRadius(6)
        }
      }

      VStack {
        Spacer()
        HStack {
          Spacer()
          Text("\(index + 1)")
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(2)
            .background(Color.black.opacity(0.6))
            .cornerRadius(3)
            .padding(4)
        }
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var fileInfoSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(url.lastPathComponent)
        .lineLimit(2)
        .truncationMode(.middle)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.primary)

      if let info = fileInfo {
        HStack(spacing: 8) {
          Text(info.size)
            .font(.caption)
            .foregroundColor(.secondary)

          Text("•")
            .font(.caption)
            .foregroundColor(.secondary)

          Text(info.duration)
            .font(.caption)
            .foregroundColor(.secondary)

          if info.resolution != "Unknown" {
            Text("•")
              .font(.caption)
              .foregroundColor(.secondary)

            Text(info.resolution)
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var backgroundView: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
  }

  private func loadPreloadedThumbnails() {
    // SIMPLIFIED FIX: ONLY use pre-loaded thumbnails from AppState
    // Don't generate thumbnails in ViewComponents - let AppState handle it
    if let thumbnail = appState.folderThumbnails[url] {
      // For all clips, use the same thumbnail (since they're from the same video)
      for index in 0..<times.count {
        clipThumbnails[index] = thumbnail
      }
      // Also set for single preview (index 0)
      if times.isEmpty {
        clipThumbnails[0] = thumbnail
      }
    }
    // If no thumbnail available, just leave it as nil - AppState will populate it eventually
  }
}

// MARK: - Filter Controls

/// Filter controls for sorting and filtering video files with integrated size slider
struct FilterControls: View {
  @Binding var filterSize: FilterSizeOption
  @Binding var filterLength: FilterLengthOption
  @Binding var filterResolution: FilterResolutionOption
  @Binding var filterFileType: FilterFileTypeOption
  @Binding var sortOption: SortOption
  @Binding var sortAscending: Bool
  let onSortChange: () -> Void
  @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220

  var body: some View {
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

      // Sort controls
      Picker("Sort by", selection: $sortOption) {
        ForEach(SortOption.allCases) { option in
          Text(option.rawValue).tag(option)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 140)
      .onChange(of: sortOption) { _, _ in
        onSortChange()
      }

      Button(action: {
        sortAscending.toggle()
        onSortChange()
      }) {
        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
      }
      .buttonStyle(.bordered)

      Spacer()

      // Player Size Slider (integrated)
      HStack(spacing: 8) {
        Text("Size:")
          .font(.caption)
          .foregroundColor(.secondary)
        Slider(value: $playerPreviewSize, in: 100...400, step: 1)
          .frame(width: 120)
        Text("\(Int(playerPreviewSize))")
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(width: 30, alignment: .trailing)
      }
    }
  }
}

// MARK: - Player Size Slider

/// Slider for adjusting player preview size
struct PlayerSizeSlider: View {
  @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220
  let compact: Bool

  var body: some View {
    HStack {
      Spacer()
      HStack(spacing: 8) {
        Slider(value: $playerPreviewSize, in: 100...400, step: 1)
          .frame(width: 160)
        Text("Player Size: ")
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
}

// MARK: - Loading Overlay

/// Loading overlay with progress indication
struct LoadingOverlay: View {
  let thumbnailsLoaded: Int
  let thumbnailsToLoad: Int

  var body: some View {
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
}

// MARK: - Settings Bar Components

/// Settings bar for the main application interface
struct SettingsBar: View {
  let folderURL: URL?
  let playbackType: PlaybackType
  let tempNumberOfClips: Int
  let tempClipLength: Int
  let speedOption: SpeedOption
  let deleteHotkey: String
  let keepHotkey: String
  let isMuted: Bool
  let totalFilesText: String
  let totalSizeText: String
  let isTextFieldDisabled: Bool
  let hotkeyFieldFocused: FocusState<Bool>.Binding
  let playbackMode: PlaybackMode
  let preloadCount: Int

  let onSelectFolder: () -> Void
  let onPlaybackTypeChange: (PlaybackType) -> Void
  let onNumberOfClipsChange: (Int) -> Void
  let onClipLengthChange: (Int) -> Void
  let onSpeedOptionChange: (SpeedOption) -> Void
  let onDeleteHotkeyChange: (String) -> Void
  let onKeepHotkeyChange: (String) -> Void
  let onMuteToggle: () -> Void
  let onGoAction: () -> Void
  let onPlaybackModeChange: (PlaybackMode) -> Void
  let onPreloadCountChange: (Int) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(folderURL == nil ? "Select Video Folder" : "Change Folder") {
        onSelectFolder()
      }
      .buttonStyle(.borderedProminent)

      HStack(spacing: 6) {
        HStack(spacing: 2) {
          Text("Type:").frame(width: 40, alignment: .leading)
          Picker(
            "",
            selection: Binding(
              get: { playbackType },
              set: { onPlaybackTypeChange($0) }
            )
          ) {
            ForEach(PlaybackType.allCases) { type in
              Text(type.rawValue).tag(type)
            }
          }
          .frame(width: 80)
        }

        if playbackType == .clips {
          HStack(spacing: 2) {
            Text("Clips:").frame(width: 40, alignment: .leading)
            Stepper(
              value: Binding(
                get: { tempNumberOfClips },
                set: { onNumberOfClipsChange($0) }
              ), in: 1...10
            ) {
              Text("\(tempNumberOfClips)")
            }
            .frame(width: 60)
          }

          HStack(spacing: 2) {
            Text("Length:").frame(width: 50, alignment: .leading)
            Stepper(
              value: Binding(
                get: { tempClipLength },
                set: { onClipLengthChange($0) }
              ), in: 1...10
            ) {
              Text("\(tempClipLength)s")
            }
            .frame(width: 60)
          }
        } else {
          HStack(spacing: 2) {
            Text("Speed:").frame(width: 40, alignment: .leading)
            Picker(
              "",
              selection: Binding(
                get: { speedOption },
                set: { onSpeedOptionChange($0) }
              )
            ) {
              ForEach(SpeedOption.allCases) { speed in
                Text(speed.displayName).tag(speed)
              }
            }
            .frame(width: 80)
          }
        }

        HStack(spacing: 2) {
          Text("Preload:").frame(width: 50, alignment: .leading)
          Stepper(
            value: Binding(
              get: { preloadCount },
              set: { onPreloadCountChange($0) }
            ), in: 0...10
          ) {
            Text("\(preloadCount)")
          }
          .frame(width: 60)
        }

        HStack(spacing: 2) {
          Text("Delete:").frame(width: 50, alignment: .leading)
          TextField(
            "",
            text: Binding(
              get: { deleteHotkey.uppercased() },
              set: { onDeleteHotkeyChange($0.uppercased()) }
            ),
            onCommit: {
              hotkeyFieldFocused.wrappedValue = false
              DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
              }
            }
          )
          .frame(width: 36, height: 24)
          .multilineTextAlignment(.center)
          .textFieldStyle(.roundedBorder)
          .disabled(isTextFieldDisabled)
          .focused(hotkeyFieldFocused)
          .onTapGesture {
            // Clear focus when tapping elsewhere
          }
        }

        HStack(spacing: 2) {
          Text("Keep:").frame(width: 40, alignment: .leading)
          TextField(
            "",
            text: Binding(
              get: { keepHotkey.uppercased() },
              set: { onKeepHotkeyChange($0.uppercased()) }
            ),
            onCommit: {
              hotkeyFieldFocused.wrappedValue = false
              DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
              }
            }
          )
          .frame(width: 36, height: 24)
          .multilineTextAlignment(.center)
          .textFieldStyle(.roundedBorder)
          .disabled(isTextFieldDisabled)
          .focused(hotkeyFieldFocused)
          .onTapGesture {
            // Clear focus when tapping elsewhere
          }
        }

        HStack(spacing: 4) {
          Toggle(
            isOn: Binding(
              get: { isMuted },
              set: { _ in onMuteToggle() }
            )
          ) {
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
          onGoAction()
        }
        .buttonStyle(.borderedProminent)
      }

      Spacer()

      Picker(
        "Mode:",
        selection: Binding(
          get: { playbackMode },
          set: { onPlaybackModeChange($0) }
        )
      ) {
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
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial)
    .tint(.blue)
  }
}

// MARK: - Folder Collection Bottom Bar

/// Bottom bar for folder collection navigation
struct FolderCollectionBottomBar: View {
  let folderURL: URL?
  let currentFolderIndex: Int
  let folderCollectionCount: Int

  let onPreviousFolder: () -> Void
  let onNextFolder: () -> Void
  let onDeleteFolder: () -> Void

  var body: some View {
    VStack {
      Spacer()
      HStack {
        Button(action: onPreviousFolder) {
          Image(systemName: "chevron.left")
          Text("Previous")
        }
        .disabled(currentFolderIndex == 0)

        Spacer()

        Text(folderURL?.lastPathComponent ?? "")
          .font(.headline)

        Spacer()

        Button(action: onDeleteFolder) {
          HStack(spacing: 4) {
            Image(systemName: "trash")
            Text("Delete Entire Folder")
          }
        }
        .buttonStyle(.bordered)
        .foregroundColor(.red)
        .disabled(folderURL == nil)

        Spacer()

        Text("\(currentFolderIndex + 1) / \(folderCollectionCount)")
          .font(.subheadline)
          .foregroundColor(.secondary)

        Spacer()

        Button(action: onNextFolder) {
          Text("Next")
          Image(systemName: "chevron.right")
        }
        .disabled(currentFolderIndex >= folderCollectionCount - 1)
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
