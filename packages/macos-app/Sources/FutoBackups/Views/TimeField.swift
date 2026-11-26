import AppKit
import SwiftUI

struct TimeField: View {
  @Binding var time: Date

  var body: some View {
    BorderlessTimePicker(time: $time)
      .fixedSize()
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(.quaternary, in: .capsule)
  }
}

private struct BorderlessTimePicker: NSViewRepresentable {
  @Binding var time: Date

  func makeNSView(context: Context) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textField
    picker.datePickerElements = .hourMinute
    picker.isBezeled = false
    picker.isBordered = false
    picker.drawsBackground = false
    picker.font = .systemFont(ofSize: NSFont.systemFontSize)
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.timeChanged(_:))
    return picker
  }

  func updateNSView(_ picker: NSDatePicker, context: Context) {
    context.coordinator.time = $time
    if picker.dateValue != time {
      picker.dateValue = time
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(time: $time)
  }

  @MainActor
  final class Coordinator: NSObject {
    var time: Binding<Date>

    init(time: Binding<Date>) {
      self.time = time
    }

    @objc func timeChanged(_ sender: NSDatePicker) {
      time.wrappedValue = sender.dateValue
    }
  }
}
