import AVFoundation
import Foundation
import SwiftUI

// MARK: - Global Utilities

/// Executes an async operation with a timeout
/// - Parameters:
///   - seconds: Timeout duration in seconds
///   - operation: The async operation to execute
/// - Returns: The result of the operation
/// - Throws: CancellationError if timeout is reached
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

// MARK: - File Utilities

extension FileManager {
  /// Supported video file extensions
  static let videoExtensions = ["mp4", "mov", "m4v", "avi", "mpg", "mpeg", "mkv"]

  /// Checks if a file has a supported video extension
  /// - Parameter url: The file URL to check
  /// - Returns: True if the file is a supported video format
  func isVideoFile(_ url: URL) -> Bool {
    return Self.videoExtensions.contains(url.pathExtension.lowercased())
  }
}

/// Formats file size in bytes to human-readable format
/// - Parameter bytes: File size in bytes
/// - Returns: Formatted string (e.g., "1.5 GB", "500 MB")
func formatFileSize(bytes: UInt64) -> String {
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

/// Parses duration string (e.g., "3:15") to seconds
/// - Parameter durationString: Duration in "MM:SS" format
/// - Returns: Duration in seconds, or nil if parsing fails
func durationInSeconds(from durationString: String) -> Double? {
  let parts = durationString.split(separator: ":").map { Double($0) ?? 0 }
  guard parts.count == 2 else { return nil }
  return parts[0] * 60 + parts[1]
}

/// Converts seconds to formatted time string
/// - Parameter seconds: Time in seconds
/// - Returns: Formatted time string in "M:SS" format
func timeString(from seconds: Double) -> String {
  guard seconds.isFinite && seconds >= 0 else { return "0:00" }
  let minutes = Int(seconds) / 60
  let secs = Int(seconds) % 60
  return String(format: "%d:%02d", minutes, secs)
}

/// Alias for timeString function for consistent naming
/// - Parameter seconds: Duration in seconds
/// - Returns: Formatted duration string
func formatDuration(_ seconds: Double) -> String {
  return timeString(from: seconds)
}

// MARK: - Video Utilities

/// Generates a unique thumbnail cache key
/// - Parameters:
///   - url: Video file URL
///   - time: Time offset for thumbnail
/// - Returns: Unique cache key string
func thumbnailKey(url: URL, time: Double) -> String {
  return url.absoluteString + "_" + String(format: "%.2f", time)
}

/// Optimized thumbnail generation utility with unified configuration
/// - Parameters:
///   - url: Video file URL
///   - time: Time offset (default: 2% of duration)
///   - maxSize: Maximum thumbnail size (default: 600x338)
///   - highQuality: Use high quality settings for folder view
/// - Returns: Generated thumbnail image
func generateOptimizedThumbnail(
  for url: URL,
  at time: Double? = nil,
  maxSize: CGSize = CGSize(width: 600, height: 338),
  highQuality: Bool = false
) async -> Image? {
  do {
    let asset = AVURLAsset(url: url)

    // Use modern async API for duration
    let duration = try await asset.load(.duration).seconds
    let targetTime = time ?? (duration * 0.02)  // Default to 2% of duration

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maxSize

    if highQuality {
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
    }

    let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)

    // Use modern async API for thumbnail generation
    let (cgImage, _) = try await generator.image(at: cmTime)

    #if canImport(AppKit)
      let nsImage = NSImage(
        cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
      return Image(nsImage: nsImage)
    #else
      let uiImage = UIImage(cgImage: cgImage)
      return Image(uiImage: uiImage)
    #endif

  } catch {
    return nil
  }
}

/// Computes evenly distributed clip start times for a video
/// - Parameters:
///   - duration: Total video duration in seconds
///   - count: Number of clips to generate
/// - Returns: Array of start times in seconds
func computeClipStartTimes(duration: Double, count: Int) -> [Double] {
  guard duration > 0, count > 0 else { return [] }
  let start = duration * 0.02  // Start at 2% of video
  let interval = (duration * 0.96) / Double(count)  // Distribute remaining 96% evenly
  return (0..<count).map { start + Double($0) * interval }
}

/// Generates clip times for a video URL
/// - Parameters:
///   - url: Video file URL
///   - count: Number of clips to generate
/// - Returns: Array of clip start times
func getClipTimes(for url: URL, count: Int) -> [Double] {
  // For now, generate default clip times based on a standard duration
  // In a real implementation, this would load the actual video duration
  let estimatedDuration: Double = 60.0  // Assume 60 seconds as default
  return computeClipStartTimes(duration: estimatedDuration, count: count)
}

// MARK: - Performance Utilities

/// Throttles function execution to improve performance
/// - Parameters:
///   - interval: Minimum time between executions
///   - action: Action to throttle
/// - Returns: Throttled action
func throttle<T>(_ interval: TimeInterval, action: @escaping (T) -> Void) -> (T) -> Void {
  var lastExecuted = Date.distantPast
  return { input in
    let now = Date()
    if now.timeIntervalSince(lastExecuted) >= interval {
      lastExecuted = now
      action(input)
    }
  }
}

// MARK: - SwiftUI Extensions

/// Non-focusable text field style to prevent automatic focus
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

// MARK: - Window Management

/// Configures window transparency and appearance
/// - Parameter folderName: Optional folder name for window title
func configureWindowTransparency(folderName: String? = nil) {
  if let window = NSApplication.shared.windows.first {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .visible
    window.isOpaque = false
    window.backgroundColor = .clear
    window.isMovableByWindowBackground = true
    window.title = folderName ?? "Cullr"
    window.makeFirstResponder(nil)
  }
}

// MARK: - Array Extensions

extension Array {
  /// Splits the array into chunks of the specified size
  /// - Parameter size: The maximum size of each chunk
  /// - Returns: An array of arrays, each containing at most `size` elements
  func chunked(into size: Int) -> [[Element]] {
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}
