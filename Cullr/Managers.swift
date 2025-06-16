import AppKit
import Combine
import Foundation
import Quartz

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
