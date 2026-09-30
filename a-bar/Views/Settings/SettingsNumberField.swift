// Purpose: Allow empty numeric edits without restoring the old value when the parent view refreshes.
//
// Logic:
// 1. Store the editing text separately from the valid numeric value.
// 2. Write only fully parsed, finite numbers to the binding, preserving empty or partial input.
// 3. Format the value on blur or Return, and sync external settings changes to the field.
//
// Required input:
// - A Binding to a CGFloat, Double, or Int setting.
// Expected output:
// - An editable numeric field that publishes valid numeric updates.
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
