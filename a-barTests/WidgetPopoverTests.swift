import AppKit
import SwiftUI
import XCTest

final class WidgetPopoverTests: XCTestCase {
  @MainActor
  func testMountedAudioContentsFollowAppearanceWithoutSavingOrChangingAudio() throws {
    let app = NSApplication.shared
    let previousAppearance = app.appearance
    defer { app.appearance = previousAppearance }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("settings.json")
    var initial = ABarSettings()
    initial.theme.appearance = .auto
    initial.theme.lightTheme = .dayShift
    initial.theme.darkTheme = .catppuccinMocha
    initial.global.noColorInDataWidgets = false
    SettingsCodec.normalize(&initial)
    let data = try SettingsCodec.encode(initial)
    try data.write(to: config)
    let settings = SettingsManager(store: SettingsStore(fileURL: config))
    let systemInfo = SystemInfoService(settingsManager: settings)
    let contents = [
      AnyView(SoundWidget.PopoverContent(
        sliderValue: 0.5, onCommit: { _ in }, onToggleMute: {}, onOpenPrefs: {})),
      AnyView(MicWidget.PopoverContent(
        sliderValue: 0.5, onCommit: { _ in }, onToggleMute: {}, onOpenPrefs: {})),
    ]
    for content in contents {
      app.appearance = NSAppearance(named: .aqua)
      let host = NSHostingView(rootView: content
        .environmentObject(settings).environmentObject(systemInfo).frame(width: 240))
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer { window.close() }
      func backgroundRed() throws -> CGFloat {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 8)?
          .usingColorSpace(.sRGB)).redComponent
      }
      let light = try backgroundRed()
      app.appearance = NSAppearance(named: .darkAqua)
      XCTAssertLessThan(try backgroundRed(), light - 0.5)
      app.appearance = NSAppearance(named: .aqua)
      XCTAssertEqual(try backgroundRed(), light, accuracy: 0.01)
    }
    XCTAssertEqual(settings.settings, initial)
    XCTAssertEqual(settings.saveState, .idle)
    XCTAssertEqual(try Data(contentsOf: config), data)
  }

  @MainActor
  func testQueuedOpeningCannotReviveAReplacedOrClosedPanel() throws {
    _ = NSApplication.shared
    let screen = try XCTUnwrap(NSScreen.main)
    let anchorWindow = NSWindow(
      contentRect: NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 40, height: 25),
      styleMask: .borderless, backing: .buffered, defer: false)
    anchorWindow.isReleasedWhenClosed = false
    let anchor = try XCTUnwrap(anchorWindow.contentView)
    let first = WidgetPopoverManager()
    let second = WidgetPopoverManager(minWidth: 400, maxHeight: 520, alignment: .trailing)
    let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    defer {
      WidgetPopoverManager.closeAll()
      anchorWindow.close()
    }
    for manager in [first, second] {
      manager.attach(anchorView: anchor, position: .top)
      manager.setContent { Color.clear.frame(width: 180, height: 40) }
    }

    first.open()
    second.open()
    let panels = NSApp.windows.compactMap { $0 as? NSPanel }
      .filter { !previousWindows.contains(ObjectIdentifier($0)) }
    // Exercise real AppKit visibility without putting test UI over the user's windows.
    panels.forEach { $0.alphaValue = 0 }
    drainMainQueue()
    XCTAssertEqual(panels.count, 2)
    XCTAssertFalse(first.isOpen)
    XCTAssertTrue(second.isOpen)
    XCTAssertEqual(panels.filter(\.isVisible).count, 1)
    XCTAssertEqual(try XCTUnwrap(panels.first(where: \.isVisible)).frame.width, 400, accuracy: 1)

    WidgetPopoverManager.closeAll()
    first.open()
    first.close()
    drainMainQueue()
    XCTAssertFalse(first.isOpen)
    XCTAssertTrue(panels.allSatisfy { !$0.isVisible })

    first.open()
    WidgetPopoverManager.closeAll()
    drainMainQueue()
    XCTAssertFalse(first.isOpen)
    XCTAssertTrue(panels.allSatisfy { !$0.isVisible })
  }

  @MainActor
  private func drainMainQueue() {
    let drained = expectation(description: "queued panel operations")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }
}
