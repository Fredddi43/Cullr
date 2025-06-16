import Foundation

// MARK: - Playback Configuration Models

/// Defines the different viewing modes for video content
enum PlaybackMode: String, CaseIterable, Identifiable {
  case folderView = "Folder View Mode"
  case single = "Single Clip Mode"
  case sideBySide = "Side-by-Side Clips"
  case batchList = "Batch List Mode"

  var id: String { self.rawValue }
}

/// Defines the type of playback behavior
enum PlaybackType: String, CaseIterable, Identifiable {
  case clips = "Clips"
  case speed = "Speed"

  var id: String { self.rawValue }
}

/// Available speed multiplier options for video playback
enum SpeedOption: Double, CaseIterable, Identifiable {
  case x2 = 2.0
  case x4 = 4.0
  case x8 = 8.0
  case x12 = 12.0
  case x16 = 16.0
  case x24 = 24.0
  case x32 = 32.0
  case x40 = 40.0
  case x48 = 48.0
  case x60 = 60.0

  var id: Double { self.rawValue }
  var displayName: String { "x\(Int(self.rawValue))" }
}

// MARK: - Sorting and Filtering Models

/// Options for sorting video files
enum SortOption: String, CaseIterable, Identifiable {
  case name = "Name"
  case dateAdded = "Date Added"
  case dateModified = "Date Modified"
  case size = "Size"
  case duration = "Video Length"

  var id: String { self.rawValue }
}

/// File size filtering options
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

/// Video duration filtering options
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

/// Video resolution filtering options
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

/// File type filtering options
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

// MARK: - UI Models

/// Types of confirmation alerts
enum AlertType {
  case fileDelete
  case folderDelete
}

/// Video file metadata information
typealias FileInfo = (size: String, duration: String, resolution: String, fps: String)
