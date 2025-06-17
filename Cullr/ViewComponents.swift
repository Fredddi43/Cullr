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
  @State private var thumbnailRequestIds: [UUID] = []
  @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220

  var body: some View {
    HStack(spacing: 12) {
      // Video preview section
      if playbackType == .clips && times.count > 1 {
        // Show clips side-by-side when in clips mode
        let clipWidth = playerPreviewSize * 0.545  // Same size as folder view
        let clipHeight = playerPreviewSize * 0.309  // Same size as folder view

        HStack(spacing: 2) {
          ForEach(Array(times.enumerated()), id: \.offset) { index, time in
            ZStack {
              // Background thumbnail - unique for each clip
              if let thumbnail = clipThumbnails[index] {
                thumbnail
                  .resizable()
                  .aspectRatio(16 / 9, contentMode: .fill)
                  .frame(width: clipWidth, height: clipHeight)
                  .clipped()
                  .cornerRadius(6)
              } else {
                Rectangle()
                  .fill(Color.gray.opacity(0.3))
                  .frame(width: clipWidth, height: clipHeight)
                  .cornerRadius(6)
              }

              // Individual clip preview - show for all clips when hovered
              if isRowHovered {
                SingleClipPreview(
                  url: url,
                  startTime: time,
                  isMuted: isMuted
                )
                .frame(width: clipWidth, height: clipHeight)
                .cornerRadius(6)
              }

              // Clip number overlay
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
        }
        .frame(
          width: clipWidth * CGFloat(times.count) + CGFloat((times.count - 1) * 2),
          height: clipHeight)  // Dynamic width based on actual clip count
      } else {
        // Single preview for speed mode or single clip
        let singleWidth = playerPreviewSize * 0.545
        let singleHeight = playerPreviewSize * 0.309

        ZStack {
          // Background thumbnail
          if let thumbnail = clipThumbnails[0] {
            thumbnail
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: singleWidth, height: singleHeight)
              .clipped()
              .cornerRadius(8)
          } else {
            Rectangle()
              .fill(Color.gray.opacity(0.3))
              .frame(width: singleWidth, height: singleHeight)
              .cornerRadius(8)
          }

          // Hover preview overlay
          if isRowHovered {
            HoverPreviewCard(
              url: url,
              times: playbackType == .clips ? times : [0.02],
              isMuted: isMuted,
              playbackType: playbackType,
              speedOption: speedOption,
              forcePlay: true
            )
            .frame(width: singleWidth, height: singleHeight)
            .cornerRadius(8)
          }
        }
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
      }

      // File info section
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

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering in
      onHoverChanged(hovering)
    }
    .onTapGesture(count: 2) {
      print("Double-click detected on batch row: \(url.lastPathComponent)")
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
    .task {
      // Load thumbnails for each clip at their specific times
      for (index, time) in times.enumerated() {
        // Skip if already loaded
        guard clipThumbnails[index] == nil else { continue }

        let cacheKey = thumbnailKey(url: url, time: time)

        if let cached = ThumbnailCache.shared.get(for: cacheKey) {
          clipThumbnails[index] = cached
        } else {
          // Use throttled thumbnail generation with normal priority for batch thumbnails
          let requestId = ThumbnailCache.shared.requestThumbnail(
            for: url, at: time, priority: .normal
          ) { image in
            Task { @MainActor in
              self.clipThumbnails[index] = image
            }
          }
          thumbnailRequestIds.append(requestId)
        }
      }
    }
    .onDisappear {
      // Cancel pending thumbnail requests when view disappears
      for requestId in thumbnailRequestIds {
        ThumbnailCache.shared.cancelRequest(requestId)
      }
      thumbnailRequestIds.removeAll()
    }
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
