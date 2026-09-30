// 代码目的：验证设置页数字编辑能保留空文本，避免删除后输入 24 得到 224。
//
// 代码逻辑：
// 1. 使用临时配置和真实 SettingsManager 挂载设置视图。
// 2. 在隐藏窗口中操作原生 field editor，覆盖快速和慢速删除。
// 3. 跨过未保存状态的延迟通知，检查输入文本与最终保存数值。
//
// 必需输入：
// - 测试 target 中的设置模型与 SwiftUI 设置视图。
// 预期输出：
// - XCTest 回归结果；不读写正式用户配置。
import SwiftUI
import XCTest

final class SettingsNumberFieldTests: XCTestCase {
  @MainActor
  func testBarHeightCanBeClearedThenReplacedAcrossDraftRefreshes() throws {
    for deletionDelay in [0.01, 0.4] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let config = directory.appendingPathComponent("settings.json")
      var initial = ABarSettings()
      initial.global.barHeight = 25
      try SettingsCodec.encode(initial).write(to: config)
      let manager = SettingsManager(store: SettingsStore(fileURL: config))
      let host = NSHostingView(rootView: AppearanceSettingsView().environmentObject(manager))
      let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 660, height: 1600),
        styleMask: .titled, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer { window.close() }
      settle(0.1)
      host.layoutSubtreeIfNeeded()
      let field = try XCTUnwrap(fields(in: host).first { $0.isEditable && $0.stringValue == "25" })
      field.selectText(nil)
      let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
      editor.setSelectedRange(NSRange(location: 2, length: 0))

      editor.deleteBackward(nil)
      settle(deletionDelay)
      editor.deleteBackward(nil)
      settle(0.4) // The real manager publishes its dirty state after 300 ms.
      XCTAssertTrue(
        editor.string.isEmpty, "clearing must survive parent refresh, delay=\(deletionDelay)")
      editor.insertText("2", replacementRange: editor.selectedRange())
      settle(0.4)
      XCTAssertEqual(manager.settings.global.barHeight, 25, "editing must remain a draft")
      XCTAssertTrue(manager.hasUnsavedChanges)
      editor.insertText("4", replacementRange: editor.selectedRange())
      XCTAssertEqual(
        manager.draftSettings.global.barHeight, 24,
        "save immediately after typing must see the final digit")
      manager.saveSettings()
      manager.flush()
      XCTAssertEqual(manager.settings.global.barHeight, 24)
      XCTAssertEqual(SettingsStore(fileURL: config).load().settings.global.barHeight, 24)
      settle(0.4)
      XCTAssertEqual(editor.string, "24")
    }
  }

  @MainActor
  func testNumberTypesPreservePartialInputAndFollowExternalChanges() throws {
    try checkField(\.global.barHorizontalPadding, fractionalValue: CGFloat(24.5))
    try checkField(\.widgets.cpu.refreshInterval, fractionalValue: Double(24.5))
    try checkField(\.widgets.hackerNews.maxTitleLength, fractionalValue: Int(24))
  }

  @MainActor
  private func checkField<Value: Numeric>(
    _ keyPath: WritableKeyPath<ABarSettings, Value>, fractionalValue: Value
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("settings.json")
    var initial = ABarSettings()
    initial[keyPath: keyPath] = 25
    try SettingsCodec.encode(initial).write(to: config)
    let manager = SettingsManager(store: SettingsStore(fileURL: config))
    let host = NSHostingView(rootView: NumberFieldProbe(manager: manager, keyPath: keyPath))
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 60),
      styleMask: .titled, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    settle(0.1)
    let field = try XCTUnwrap(fields(in: host).first { $0.isEditable })
    field.selectText(nil)
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.insertText("24", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    let separator = NumberFormatter().decimalSeparator ?? "."
    editor.insertText(separator, replacementRange: editor.selectedRange())
    settle(0.4)
    XCTAssertEqual(editor.string, "24" + separator, "parent refresh must preserve a partial decimal")
    editor.insertText("5", replacementRange: editor.selectedRange())
    XCTAssertEqual(manager.draftSettings[keyPath: keyPath], fractionalValue)

    for invalid in ["", "-", "24a", "NaN", "Inf", "1e999"] {
      editor.insertText(invalid, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
      manager.objectWillChange.send()
      settle(0.1)
      XCTAssertEqual(editor.string, invalid, "invalid partial text must remain editable")
      XCTAssertEqual(manager.draftSettings[keyPath: keyPath], fractionalValue)
    }
    XCTAssertTrue(window.makeFirstResponder(nil))
    settle(0.1)
    XCTAssertNil(field.currentEditor())
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    XCTAssertEqual(field.stringValue, formatter.string(for: fractionalValue))

    manager.discardChanges()
    settle(0.1)
    XCTAssertEqual(field.stringValue, "25", "discard must restore an external value")
    manager.draftSettings[keyPath: keyPath] = 30
    settle(0.1)
    XCTAssertEqual(field.stringValue, "30")
    XCTAssertEqual(manager.settings[keyPath: keyPath], 25)
  }

  @MainActor
  private func settle(_ duration: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
  }

  @MainActor
  private func fields(in view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField { return [field] }
    return view.subviews.flatMap { fields(in: $0) }
  }
}

private struct NumberFieldProbe<Value: Numeric>: View {
  @ObservedObject var manager: SettingsManager
  let keyPath: WritableKeyPath<ABarSettings, Value>

  var body: some View {
    SettingsNumberField(value: Binding(
      get: { manager.draftSettings[keyPath: keyPath] },
      set: { manager.draftSettings[keyPath: keyPath] = $0 }))
  }
}
