import AVFoundation
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
  private let maxCacheSize = 500
  private let queue = DispatchQueue(label: "thumbnail-cache", qos: .userInitiated)

  // Throttling system - NUCLEAR OPTION: Only 1 concurrent operation
  private var activeRequests: [UUID: ThumbnailRequest] = [:]
  private var pendingRequests: [ThumbnailRequest] = []
  private var currentlyGenerating = 0
  private let maxConcurrentGenerations = 1  // NUCLEAR OPTION: Reduced to 1

  private struct ThumbnailRequest {
    let id: UUID
    let url: URL
    let time: Double
    let priority: Priority
    let completion: (Image?) -> Void
    let createdAt: Date
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

  @discardableResult
  func requestThumbnail(
    for url: URL, at time: Double, priority: Priority = .normal,
    completion: @escaping (Image?) -> Void
  ) -> UUID {
    let requestId = UUID()
    let request = ThumbnailRequest(
      id: requestId,
      url: url,
      time: time,
      priority: priority,
      completion: completion,
      createdAt: Date()
    )

    queue.async {
      print(
        "🎬 ThumbnailCache: Requesting thumbnail for \(url.lastPathComponent) at \(time)s (priority: \(priority))"
      )
      self.activeRequests[requestId] = request
      self.processNextRequest()
    }

    return requestId
  }

  func cancelRequest(_ requestId: UUID) {
    queue.async {
      print("❌ ThumbnailCache: Cancelling request \(requestId)")
      self.activeRequests.removeValue(forKey: requestId)
      self.pendingRequests.removeAll { $0.id == requestId }
    }
  }

  private func processNextRequest() {
    guard currentlyGenerating < maxConcurrentGenerations else {
      print(
        "⏳ ThumbnailCache: Already generating \(currentlyGenerating)/\(maxConcurrentGenerations) thumbnails"
      )
      return
    }

    // Find highest priority request
    let allRequests = Array(activeRequests.values) + pendingRequests
    guard
      let nextRequest = allRequests.max(by: {
        $0.priority < $1.priority || ($0.priority == $1.priority && $0.createdAt > $1.createdAt)
      })
    else {
      return
    }

    // Remove from pending and active
    activeRequests.removeValue(forKey: nextRequest.id)
    pendingRequests.removeAll { $0.id == nextRequest.id }

    currentlyGenerating += 1
    print(
      "🚀 ThumbnailCache: Starting generation for \(nextRequest.url.lastPathComponent) (\(currentlyGenerating)/\(maxConcurrentGenerations) active)"
    )

    Task {
      let image = await self.generateThumbnailWithTimeout(
        url: nextRequest.url, time: nextRequest.time)

      await MainActor.run {
        nextRequest.completion(image)
      }

      self.queue.async {
        self.currentlyGenerating -= 1
        print(
          "✅ ThumbnailCache: Completed generation for \(nextRequest.url.lastPathComponent) (\(self.currentlyGenerating)/\(self.maxConcurrentGenerations) active)"
        )
        self.processNextRequest()
      }
    }
  }

  private func generateThumbnailWithTimeout(url: URL, time: Double) async -> Image? {
    print("⏱️ ThumbnailCache: Generating thumbnail for \(url.lastPathComponent) with 3s timeout")

    return await withTaskGroup(of: Image?.self) { group in
      // Add thumbnail generation task
      group.addTask {
        return await self.generateAsyncThumbnail(url: url, time: time)
      }

      // Add timeout task
      group.addTask {
        try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds
        print("⏰ ThumbnailCache: Timeout reached for \(url.lastPathComponent)")
        return nil
      }

      // Return first completed result and cancel others
      if let result = await group.next() {
        group.cancelAll()
        return result
      }

      return nil
    }
  }

  private func generateAsyncThumbnail(url: URL, time: Double) async -> Image? {
    print("🎯 ThumbnailCache: Actually generating thumbnail for \(url.lastPathComponent)")

    return await withCheckedContinuation { continuation in
      let asset = AVAsset(url: url)
      let imageGenerator = AVAssetImageGenerator(asset: asset)
      imageGenerator.appliesPreferredTrackTransform = true
      imageGenerator.maximumSize = CGSize(width: 300, height: 300)

      let cmTime = CMTime(seconds: time, preferredTimescale: 600)

      imageGenerator.generateCGImageAsynchronously(for: cmTime) { cgImage, actualTime, error in
        if let error = error {
          print(
            "❌ ThumbnailCache: Error generating thumbnail for \(url.lastPathComponent): \(error)"
          )
          continuation.resume(returning: nil)
          return
        }

        guard let cgImage = cgImage else {
          print("❌ ThumbnailCache: No image generated for \(url.lastPathComponent)")
          continuation.resume(returning: nil)
          return
        }

        let image = Image(decorative: cgImage, scale: 1.0)
        let key = self.thumbnailKey(url: url, time: time)
        self.set(image, for: key)

        print("✨ ThumbnailCache: Successfully generated thumbnail for \(url.lastPathComponent)")
        continuation.resume(returning: image)
      }
    }
  }

  private func thumbnailKey(url: URL, time: Double) -> String {
    return "\(url.path)_\(time)"
  }
}
