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

  @State private var thumbnail: Image?
  @AppStorage("playerPreviewSize") private var playerPreviewSize: Double = 220

  var body: some View {
    HStack {
      HStack(spacing: 8) {
        if playbackType == .clips {
          ForEach(times, id: \.self) { time in
            HoverPreviewCard(
              url: url,
              thumbnail: staticThumbnails[thumbnailKey(url: url, time: time)],
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
            startTime: 0.02,
            forcePlay: isRowHovered,
            playbackType: playbackType,
            speedOption: speedOption
          )
          .frame(width: playerPreviewSize * 0.545, height: playerPreviewSize * 0.309)
          .cornerRadius(10)
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
      )

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
    .padding(.vertical, isSelected ? 12 : 8)
    .padding(.horizontal, 16)
    .task {
      // Load thumbnail exactly like folder view
      if let cached = ThumbnailCache.shared.get(url) {
        thumbnail = cached
      } else {
        do {
          let asset = AVURLAsset(url: url)
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          generator.maximumSize = CGSize(width: 600, height: 338)
          generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
          generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
          let time = max(asset.duration.seconds * 0.02, 0.1)
          let cmTime = CMTime(seconds: time, preferredTimescale: 600)
          let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
          let image = Image(decorative: cgImage, scale: 1.0)
          ThumbnailCache.shared.set(url, image: image)
          thumbnail = image
        } catch {
          // Handle error silently
        }
      }
    }
  }
}

// MARK: - Filter Controls

/// Filter controls for sorting and filtering video files
struct FilterControls: View {
  @Binding var filterSize: FilterSizeOption
  @Binding var filterLength: FilterLengthOption
  @Binding var filterResolution: FilterResolutionOption
  @Binding var filterFileType: FilterFileTypeOption

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
