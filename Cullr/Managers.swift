@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import Quartz
import SwiftUI

// MARK: - Global Hotkey Monitor

/// Manages global keyboard shortcuts for the application
class GlobalHotkeyMonitor: ObservableObject {
  private var localEventMonitor: Any?

  // Callback actions for different hotkeys
  var onSpace: (() -> Void)?
  var onDelete: (() -> Void)?
  var onKeep: (() -> Void)?

  // Configurable hotkey characters
  var deleteKey: String = "d"
  var keepKey: String = "k"

  /// Starts monitoring for keyboard events
  func startMonitoring() {
    // Monitor local events when app is focused
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if self.handleKeyEvent(event) {
        return nil  // Consume the event
      }
      return event  // Let the event continue
    }
  }

  /// Stops monitoring keyboard events
  func stopMonitoring() {
    if let monitor = localEventMonitor {
      NSEvent.removeMonitor(monitor)
      localEventMonitor = nil
    }
  }

  /// Handles individual key events
  /// - Parameter event: The keyboard event
  /// - Returns: True if the event was handled and should be consumed
  private func handleKeyEvent(_ event: NSEvent) -> Bool {
    let keyChar = event.charactersIgnoringModifiers?.lowercased() ?? ""

    if event.keyCode == 49 {  // Spacebar
      onSpace?()
      return true
    } else if keyChar == deleteKey.lowercased() {
      onDelete?()
      return true
    } else if keyChar == keepKey.lowercased() {
      onKeep?()
      return true
    }

    return false
  }

  deinit {
    stopMonitoring()
  }
}

// MARK: - Quick Look Preview Coordinator

/// Manages Quick Look preview functionality for multiple files
class QuickLookPreviewCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  static let shared = QuickLookPreviewCoordinator()

  private var urls: [URL] = []
  private var currentIndex: Int = 0

  /// Previews a collection of URLs starting at a specific index
  /// - Parameters:
  ///   - urls: Array of file URLs to preview
  ///   - index: Starting index for preview
  func preview(urls: [URL], startAt index: Int = 0) {
    self.urls = urls
    self.currentIndex = index

    // Bring app to front and show preview panel
    NSApp.activate(ignoringOtherApps: true)
    if let panel = QLPreviewPanel.shared() {
      panel.delegate = self
      panel.dataSource = self
      panel.makeKeyAndOrderFront(nil)
      panel.reloadData()
      panel.currentPreviewItemIndex = index
    }
  }

  // MARK: - QLPreviewPanelDataSource

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    return urls.count
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    return urls.indices.contains(index) ? urls[index] as QLPreviewItem : nil
  }

  // MARK: - QLPreviewPanelDelegate

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    return true
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    // Panel control begins - could add custom logic here
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    // Panel control ends - could add cleanup logic here
  }
}

class ThumbnailCache: ObservableObject, @unchecked Sendable {
  static let shared = ThumbnailCache()

  private var cache: [String: Image] = [:]
  private var accessOrder: [String] = []
  private let maxCacheSize = 500  // PERFORMANCE FIX: Reduced cache size to prevent memory issues
  private let queue = DispatchQueue(label: "thumbnail-cache", qos: .userInitiated)

  // CRITICAL PERFORMANCE FIX: Ultra-conservative concurrency to prevent freezing
  private var requestCounter: Int = 0
  private let maxConcurrentGenerations = 2  // CRITICAL FIX: Only 2 concurrent thumbnails max
  private let maxPendingRequests = 10  // CRITICAL FIX: Much smaller pending queue

  // Simple atomic counters instead of complex dictionaries
  private var currentlyGenerating = 0
  private var pendingCount = 0

  private struct ThumbnailRequest {
    let id: Int  // Use simple Int instead of UUID
    let url: URL
    let time: Double
    let priority: Priority
    let completion: (Image?) -> Void
  }

  enum Priority: Int, Comparable {
    case normal = 0
    case high = 1

    static func < (lhs: Priority, rhs: Priority) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  private init() {}

  func get(for key: String) -> Image? {
    return queue.sync {
      if let image = cache[key] {
        // Move to end (most recently used)
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        return image
      }
      return nil
    }
  }

  func set(_ image: Image, for key: String) {
    queue.async {
      self.cache[key] = image
      self.accessOrder.removeAll { $0 == key }
      self.accessOrder.append(key)

      // Evict oldest if over limit
      while self.accessOrder.count > self.maxCacheSize {
        let oldestKey = self.accessOrder.removeFirst()
        self.cache.removeValue(forKey: oldestKey)
      }
    }
  }

  func requestThumbnail(
    for url: URL, at time: Double, priority: Priority,
    completion: @escaping (Image?) -> Void
  ) -> Int {  // Return simple Int instead of UUID
    return queue.sync {
      let requestId = requestCounter
      requestCounter += 1

      let cacheKey = thumbnailKey(url: url, time: time)

      // Check cache first
      if let cached = cache[cacheKey] {
        // Call completion immediately on main queue
        DispatchQueue.main.async {
          completion(cached)
        }
        return requestId
      }

      // CRITICAL PERFORMANCE FIX: Much more conservative generation
      if currentlyGenerating < maxConcurrentGenerations {
        currentlyGenerating += 1

        // Process request on background queue
        Task {
          let image = await self.generateThumbnailFast(url: url, time: time)

          // Update cache and complete on main queue
          await MainActor.run {
            if let image = image {
              self.set(image, for: cacheKey)
            }
            completion(image)

            // Update counters on cache queue
            self.queue.async {
              self.currentlyGenerating -= 1
            }
          }
        }
      } else {
        // PERFORMANCE FIX: Reject immediately instead of queuing to prevent backlog
        DispatchQueue.main.async {
          completion(nil)
        }
      }

      return requestId
    }
  }

  func cancelRequest(_ requestId: Int) {
    queue.async {
      self.currentlyGenerating = max(0, self.currentlyGenerating - 1)
      self.pendingCount = 0
    }
  }

  // CRITICAL FIX: Complete reset for folder navigation
  func clearPendingRequests() {
    queue.async {
      self.pendingCount = 0
      self.currentlyGenerating = 0
    }
  }

  // CRITICAL FIX: Complete reset for folder navigation
  func cancelAllRequests() {
    queue.async {
      self.pendingCount = 0
      self.currentlyGenerating = 0
    }
  }

  // PERFORMANCE FIX: Ultra-fast thumbnail generation with aggressive timeouts
  private func generateThumbnailFast(url: URL, time: Double) async -> Image? {
    return await withCheckedContinuation { continuation in
      var hasResumed = false
      let resumeLock = NSLock()

      func safeResume(with result: Image?) {
        resumeLock.lock()
        defer { resumeLock.unlock() }

        if !hasResumed {
          hasResumed = true
          continuation.resume(returning: result)
        }
      }

      // PERFORMANCE FIX: Ultra-aggressive 2 second timeout to prevent hanging
      let timeoutTask = Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds max
        safeResume(with: nil)
      }

      let asset = AVAsset(url: url)
      let imageGenerator = AVAssetImageGenerator(asset: asset)
      imageGenerator.appliesPreferredTrackTransform = true
      imageGenerator.maximumSize = CGSize(width: 200, height: 200)  // PERFORMANCE FIX: Smaller thumbnails for speed
      imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)  // Allow tolerance for speed
      imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)

      // PERFORMANCE FIX: Always use a safe time, never 0
      let targetTime = max(time, 0.5)
      let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)

      imageGenerator.generateCGImageAsynchronously(for: cmTime) { cgImage, actualTime, error in
        timeoutTask.cancel()

        if let cgImage = cgImage {
          let nsImage = NSImage(cgImage: cgImage, size: NSSize.zero)
          let image = Image(nsImage: nsImage)
          safeResume(with: image)
        } else {
          // PERFORMANCE FIX: No fallback attempts - just fail fast
          safeResume(with: nil)
        }
      }
    }
  }

  private func thumbnailKey(url: URL, time: Double) -> String {
    return "\(url.path)_\(time)"
  }
}
