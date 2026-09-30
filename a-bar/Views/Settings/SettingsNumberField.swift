// 代码目的：允许数字设置在编辑时暂时为空，避免父视图刷新填回旧数字。
//
// 代码逻辑：
// 1. 将编辑文本与有效数字分别保存。
// 2. 只将能完整解析的有限数字写回绑定，保留空串等输入中间状态。
// 3. 失焦或回车时规范显示；外部设置变化仍同步到输入框。
//
// 必需输入：
// - CGFloat、Double 或 Int 设置值的 Binding。
// 预期输出：
// - 正常可编辑的数字输入框和有效数值更新。
import SwiftUI

struct SettingsNumberField<Value: Numeric>: View {
  @Binding private var value: Value
  @State private var text: String
  @State private var lastValue: Value

  init(value: Binding<Value>) {
    _value = value
    _text = State(initialValue: settingsNumberFormatter.string(for: value.wrappedValue) ?? "")
    _lastValue = State(initialValue: value.wrappedValue)
  }

  var body: some View {
    TextField("", text: Binding(get: { text }, set: acceptText), onEditingChanged: { editing in
      if !editing { finishEditing() }
    }, onCommit: finishEditing)
    .onChange(of: value) { next in
      // Own writes must not replace a blank or partial edit. An external reset must.
      guard next != lastValue else { return }
      lastValue = next
      formatValue()
    }
  }

  private func acceptText(_ next: String) {
    text = next
    guard let number = settingsNumberFormatter.number(from: next),
      number.doubleValue.isFinite, let parsed = number as? Value
    else { return }
    // Update synchronously so saving immediately after typing includes the final digit.
    lastValue = parsed
    if value != parsed { value = parsed }
  }

  private func formatValue() {
    text = settingsNumberFormatter.string(for: value) ?? ""
  }

  private func finishEditing() {
    // AppKit writes the field editor's final text after its callbacks finish.
    DispatchQueue.main.async { formatValue() }
  }
}

private let settingsNumberFormatter: NumberFormatter = {
  let formatter = NumberFormatter()
  formatter.numberStyle = .decimal
  formatter.usesGroupingSeparator = false
  formatter.maximumFractionDigits = 16
  return formatter
}()
