import Foundation

/// The string carried by a drag in the layout builder.
///
/// This is a wire format: it is written into an `NSItemProvider` in one view and read back in
/// another, so the two sides have to agree exactly. It used to be spelled out by hand at five
/// places - two encoders and three parsers - which is why an unparseable payload could be
/// silently treated as a catalog identifier and dropped on the floor.
enum WidgetDragPayload: Equatable {

  /// A widget already placed in a bar, being moved.
  case instance(UUID)

  /// A custom widget being added from the palette, identified by its index in `userWidgets`.
  case userWidget(Int)

  /// A built-in widget being added from the palette.
  case catalog(WidgetIdentifier)

  private static let instancePrefix = "widget:"
  private static let userWidgetPrefix = "userWidget:"

  init?(_ encoded: String) {
    if encoded.hasPrefix(Self.instancePrefix) {
      guard let id = UUID(uuidString: String(encoded.dropFirst(Self.instancePrefix.count))) else {
        return nil
      }
      self = .instance(id)
      return
    }

    if encoded.hasPrefix(Self.userWidgetPrefix) {
      guard let index = Int(String(encoded.dropFirst(Self.userWidgetPrefix.count))) else {
        return nil
      }
      self = .userWidget(index)
      return
    }

    guard let identifier = WidgetIdentifier(rawValue: encoded) else { return nil }
    self = .catalog(identifier)
  }

  var encoded: String {
    switch self {
    case .instance(let id): return "\(Self.instancePrefix)\(id.uuidString)"
    case .userWidget(let index): return "\(Self.userWidgetPrefix)\(index)"
    case .catalog(let identifier): return identifier.rawValue
    }
  }

  /// The widget this payload asks to add, or nil when it is moving one that already exists.
  var newInstance: WidgetInstance? {
    switch self {
    case .instance: return nil
    case .userWidget(let index): return WidgetInstance(identifier: .userWidget, userWidgetIndex: index)
    case .catalog(let identifier): return WidgetInstance(identifier: identifier)
    }
  }
}
