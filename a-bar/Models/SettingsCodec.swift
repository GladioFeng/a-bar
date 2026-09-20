import Foundation

/// Decoding, migration, repair and normalization for `ABarSettings`.
///
/// The config file outlives app versions: it gets hand-edited, it picks up values from
/// development builds that no release build knows about, and its fields accrete over time.
/// A strict decode throws on the first unrecognised value and takes the whole document with
/// it, which is how a single unknown widget identifier used to reset every setting.
///
/// Everything here follows one rule: **the blast radius of a bad value is the smallest
/// element that contains it, never the file.**
enum SettingsCodec {

  /// Schema version written to new files. Bump when adding a step to `migrate`.
  static let currentSchemaVersion = 1

  /// How many values the repair loop will fix before giving up and isolating by section.
  private static let maxRepairPasses = 200

  /// A value the decoder had to fix to make the document loadable.
  struct Repair: Equatable, CustomStringConvertible {
    enum Action: String {
      /// The value was missing or unusable and was replaced with its default.
      case filledDefault
      /// An array element could not be decoded at all and was dropped.
      case droppedElement
      /// The key had no default and no enclosing array to drop from.
      case droppedKey
      /// Last resort: a whole top-level section was reset.
      case resetSection
    }

    let path: String
    let action: Action

    var description: String { "\(path) (\(action.rawValue))" }
  }

  enum Outcome {
    /// Loadable, after applying `repairs` (empty when the document was already clean).
    case ok(ABarSettings, repairs: [Repair])
    /// Not usable JSON at all. Callers must **not** overwrite the file it came from.
    case unreadable(String)
  }

  // MARK: - Encoding

  static func encode(_ settings: ABarSettings) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(settings)
  }

  // MARK: - Decoding

  static func decode(_ data: Data) -> Outcome {
    guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
      return .unreadable("not valid JSON")
    }
    guard var root = parsed as? [String: Any] else {
      return .unreadable("top level is not a JSON object")
    }

    migrate(&root)

    // Fill every key the document is missing from the defaults, at every level.
    var merged = merge(defaults: defaultsObject, saved: root, path: [])
    var repairs: [Repair] = []
    var previous: Data?

    for _ in 0..<maxRepairPasses {
      guard
        let candidate = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
      else { break }

      // The last pass changed nothing, so retrying would spin forever.
      if candidate == previous { break }
      previous = candidate

      do {
        var settings = try JSONDecoder().decode(ABarSettings.self, from: candidate)
        normalize(&settings)
        return .ok(settings, repairs: repairs)
      } catch let error as DecodingError {
        guard let repair = repair(&merged, for: error) else { break }
        repairs.append(repair)
      } catch {
        break
      }
    }

    // The repair loop could not converge. Decode section by section so that at worst one
    // section is lost instead of the whole file.
    let (settings, sectionRepairs) = decodeSectionBySection(merged)
    return .ok(settings, repairs: repairs + sectionRepairs)
  }

  /// Fix the single value a decoding error points at, leaving everything else untouched.
  private static func repair(_ root: inout [String: Any], for error: DecodingError) -> Repair? {
    guard let path = failingPath(for: error), !path.isEmpty else { return nil }

    // A failing array element is dropped rather than replaced: substituting a template
    // here would fabricate an entry the user never created.
    let failingNodeIsArrayElement = path.last?.isIndex ?? false

    // 1. A default exists for this exact value: put it back.
    if !failingNodeIsArrayElement, let fallback = defaultValue(at: path) {
      guard update(at: path, in: &root, with: fallback) else { return nil }
      return Repair(path: describe(path), action: .filledDefault)
    }

    // 2. Inside an array: drop the innermost enclosing element. This is what turns
    //    "an unknown widget identifier resets everything" into "one widget disappears".
    if let elementDepth = path.lastIndex(where: { $0.isIndex }) {
      let elementPath = Array(path.prefix(through: elementDepth))
      guard update(at: elementPath, in: &root, with: nil) else { return nil }
      return Repair(path: describe(elementPath), action: .droppedElement)
    }

    // 3. Nothing better to do than drop the key.
    guard update(at: path, in: &root, with: nil) else { return nil }
    return Repair(path: describe(path), action: .droppedKey)
  }

  private static func failingPath(for error: DecodingError) -> [PathComponent]? {
    switch error {
    case .keyNotFound(let key, let context):
      return (context.codingPath + [key]).map(PathComponent.init(codingKey:))
    case .typeMismatch(_, let context),
      .valueNotFound(_, let context),
      .dataCorrupted(let context):
      return context.codingPath.map(PathComponent.init(codingKey:))
    @unknown default:
      return nil
    }
  }

  /// Decode one top-level section at a time, keeping the defaults for any that fail.
  private static func decodeSectionBySection(_ saved: [String: Any]) -> (ABarSettings, [Repair]) {
    var accepted = defaultsObject
    var repairs: [Repair] = []

    for key in Set(defaultsObject.keys).union(saved.keys).sorted() {
      guard let section = saved[key] else { continue }
      var candidate = accepted
      candidate[key] = section
      if decodeSettings(from: candidate) != nil {
        accepted = candidate
      } else {
        repairs.append(Repair(path: key, action: .resetSection))
      }
    }

    var settings = decodeSettings(from: accepted) ?? ABarSettings()
    normalize(&settings)
    return (settings, repairs)
  }

  private static func decodeSettings(from object: [String: Any]) -> ABarSettings? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
      return nil
    }
    return try? JSONDecoder().decode(ABarSettings.self, from: data)
  }

  // MARK: - Migration

  private static func migrate(_ root: inout [String: Any]) {
    let version = root["schemaVersion"] as? Int ?? 0

    if version < 1 {
      // Before profiles existed, the layout lived at the root as `multiDisplayLayout`. The
      // commit that introduced profiles dropped that key without a migration, so upgrading
      // users silently lost their layout. Recover it into the Default profile instead.
      let hasProfiles = (root["profiles"] as? [Any])?.isEmpty == false
      if !hasProfiles, let legacyLayout = root["multiDisplayLayout"] {
        let id = UUID().uuidString
        root["profiles"] = [
          [
            "id": id,
            "name": "Default",
            "multiDisplayLayout": legacyLayout,
            "isDefault": true,
          ]
        ]
        root["activeProfileId"] = id
      }
      root.removeValue(forKey: "multiDisplayLayout")
      root.removeValue(forKey: "layout")
    }

    root["schemaVersion"] = currentSchemaVersion
  }

  // MARK: - Defaults

  /// `ABarSettings()` encoded as JSON. Property initializers are the single source of
  /// default truth; nothing here restates a default value.
  private static let defaultsObject: [String: Any] = jsonObject(from: ABarSettings()) ?? [:]

  /// Defaults for the *elements* of arrays that have gained fields over time, keyed by the
  /// array's path with indices stripped. Without these, a config written before a field was
  /// added would lose the whole element instead of just gaining the new field.
  ///
  /// Deliberately absent: the widget-instance arrays (`…topBar.left` and friends). Their
  /// `identifier` has no meaningful default, so an unknown or missing one has to drop that
  /// one widget instance rather than silently turn it into some other widget.
  private static let arrayElementDefaults: [String: [String: Any]] = [
    "userWidgets": jsonObject(from: UserWidgetDefinition()) ?? [:],
    "profiles": jsonObject(from: LayoutProfile.defaultProfile) ?? [:],
    "profiles.multiDisplayLayout.displays": jsonObject(from: DisplayConfiguration(displayIndex: 0))
      ?? [:],
  ]

  private static func jsonObject<T: Encodable>(from value: T) -> [String: Any]? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
  }

  /// The default value for a path, walking into array element templates where needed.
  private static func defaultValue(at path: [PathComponent]) -> Any? {
    var node: Any = defaultsObject
    var stripped: [String] = []

    for component in path {
      switch component {
      case .key(let key):
        stripped.append(key)
        guard let object = node as? [String: Any], let next = object[key] else { return nil }
        node = next
      case .index:
        // Arrays in the defaults tree carry no element to descend into.
        guard let template = arrayElementDefaults[stripped.joined(separator: ".")] else {
          return nil
        }
        node = template
      }
    }

    return node
  }

  /// Merge the saved document over the defaults, recursing into objects and into the
  /// elements of arrays that have a template.
  private static func merge(defaults: [String: Any], saved: [String: Any], path: [String])
    -> [String: Any]
  {
    var result = defaults

    for (key, savedValue) in saved {
      let keyPath = path + [key]

      if let savedObject = savedValue as? [String: Any],
        let defaultObject = defaults[key] as? [String: Any]
      {
        result[key] = merge(defaults: defaultObject, saved: savedObject, path: keyPath)
      } else if let savedArray = savedValue as? [Any],
        let template = arrayElementDefaults[keyPath.joined(separator: ".")]
      {
        result[key] = savedArray.map { element -> Any in
          guard let object = element as? [String: Any] else { return element }
          return merge(defaults: template, saved: object, path: keyPath)
        }
      } else {
        result[key] = savedValue
      }
    }

    return result
  }

  // MARK: - Normalization

  /// Bring settings into a state the app can actually run on. Runs on every load path and
  /// before every save, so no value can reach the bar without passing through here.
  static func normalize(_ settings: inout ABarSettings) {
    normalizeGlobal(&settings.global)
    normalizeWidgets(&settings.widgets)
    normalizeUserWidgets(&settings.userWidgets)
    normalizeProfiles(&settings)
    settings.schemaVersion = currentSchemaVersion
  }

  private static let globalRanges: [(WritableKeyPath<GlobalSettings, CGFloat>, ClosedRange<CGFloat>)] = [
    (\.barHeight, 10...100),
    (\.fontSize, 6...72),
    (\.barHorizontalPadding, 0...50),
    (\.barVerticalPadding, 0...50),
    (\.barDistanceFromEdges, 0...50),
    (\.barCornerRadius, 0...50),
    (\.barOpacity, 0...100),
    (\.barElementsCornerRadius, 0...50),
    (\.barElementGap, 0...50),
    (\.barElementsBackgroundOpacity, 0...100),
  ]

  /// Floors for widget polling, so a bad value cannot turn a widget into a busy loop.
  private static let widgetRefreshMinimums:
    [(WritableKeyPath<WidgetSettings, TimeInterval>, TimeInterval)] = [
      (\.battery.refreshInterval, 1),
      (\.weather.refreshInterval, 60),
      (\.time.refreshInterval, 0.1),
      (\.cpu.refreshInterval, 0.5),
      (\.memory.refreshInterval, 0.5),
      (\.gpu.refreshInterval, 0.5),
      (\.netstats.refreshInterval, 0.5),
      (\.diskActivity.refreshInterval, 0.5),
      (\.storage.refreshInterval, 10),
      (\.bluetooth.refreshInterval, 1),
      (\.bluetooth.batteryRefreshInterval, 15),
      (\.wifi.refreshInterval, 5),
      // macOS rate-limits Wi-Fi scans and returns stale results for ones made too close
      // together, so this floor is about correctness as much as load.
      (\.wifi.scanInterval, 5),
    ]

  private static func normalizeGlobal(_ global: inout GlobalSettings) {
    let defaults = GlobalSettings()
    for (keyPath, range) in globalRanges {
      let value = global[keyPath: keyPath]
      global[keyPath: keyPath] =
        value.isFinite
        ? min(max(value, range.lowerBound), range.upperBound)
        : defaults[keyPath: keyPath]
    }
  }

  private static func normalizeWidgets(_ widgets: inout WidgetSettings) {
    let defaults = WidgetSettings()
    for (keyPath, minimum) in widgetRefreshMinimums {
      let value = widgets[keyPath: keyPath]
      widgets[keyPath: keyPath] =
        value.isFinite ? max(minimum, value) : defaults[keyPath: keyPath]
    }
    widgets.bluetooth.maxDeviceNameLength = min(max(widgets.bluetooth.maxDeviceNameLength, 1), 100)
    widgets.hackerNews.maxTitleLength = min(max(widgets.hackerNews.maxTitleLength, 10), 200)
    widgets.wifi.maxNetworkNameLength = min(max(widgets.wifi.maxNetworkNameLength, 1), 100)
  }

  private static func normalizeUserWidgets(_ widgets: inout [UserWidgetDefinition]) {
    for index in widgets.indices {
      widgets[index].refreshInterval = max(1, widgets[index].refreshInterval)
      widgets[index].cycleDuration = max(1, widgets[index].cycleDuration)
    }
  }

  /// Enforce the invariants the rest of the app assumes: at least one profile, unique ids
  /// and names, exactly one default, and an active id that actually resolves.
  private static func normalizeProfiles(_ settings: inout ABarSettings) {
    var seenIds: Set<UUID> = []
    var seenNames: Set<String> = []
    var profiles: [LayoutProfile] = []

    for profile in settings.profiles {
      var resolved = profile

      if seenIds.contains(resolved.id) {
        resolved = LayoutProfile(
          id: UUID(),
          name: resolved.name,
          multiDisplayLayout: resolved.multiDisplayLayout,
          isDefault: resolved.isDefault
        )
      }
      seenIds.insert(resolved.id)

      var name = resolved.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if name.isEmpty { name = "Profile" }
      if seenNames.contains(name.lowercased()) {
        var suffix = 2
        while seenNames.contains("\(name) \(suffix)".lowercased()) { suffix += 1 }
        name = "\(name) \(suffix)"
      }
      seenNames.insert(name.lowercased())
      resolved.name = name

      profiles.append(resolved)
    }

    if profiles.isEmpty { profiles = [.defaultProfile] }

    // Exactly one default profile, so there is always something to fall back to.
    if let firstDefault = profiles.firstIndex(where: { $0.isDefault }) {
      for index in profiles.indices where index != firstDefault {
        profiles[index].isDefault = false
      }
    } else {
      profiles[0].isDefault = true
    }

    settings.profiles = profiles

    // A dangling active id leaves the bar on an empty layout forever.
    let active = settings.activeProfileId.flatMap(UUID.init(uuidString:))
    if active == nil || !profiles.contains(where: { $0.id == active }) {
      settings.activeProfileId = (profiles.first { $0.isDefault } ?? profiles[0]).id.uuidString
    }
  }

  // MARK: - JSON paths

  private enum PathComponent {
    case key(String)
    case index(Int)

    init(codingKey: CodingKey) {
      if let index = codingKey.intValue {
        self = .index(index)
      } else {
        self = .key(codingKey.stringValue)
      }
    }

    var isIndex: Bool {
      if case .index = self { return true }
      return false
    }
  }

  private static func describe(_ path: [PathComponent]) -> String {
    path.reduce(into: "") { result, component in
      switch component {
      case .key(let key):
        result += result.isEmpty ? key : ".\(key)"
      case .index(let index):
        result += "[\(index)]"
      }
    }
  }

  /// Replace the value at `path` with `value`, or remove it when `value` is nil.
  private static func update(at path: [PathComponent], in root: inout [String: Any], with value: Any?)
    -> Bool
  {
    var node: Any = root
    guard update(&node, at: path[...], with: value), let object = node as? [String: Any] else {
      return false
    }
    root = object
    return true
  }

  private static func update(_ node: inout Any, at path: ArraySlice<PathComponent>, with value: Any?)
    -> Bool
  {
    guard let component = path.first else { return false }
    let rest = path.dropFirst()

    switch component {
    case .key(let key):
      guard var object = node as? [String: Any] else { return false }
      if rest.isEmpty {
        if let value = value {
          object[key] = value
        } else {
          object.removeValue(forKey: key)
        }
      } else {
        guard var child = object[key], update(&child, at: rest, with: value) else { return false }
        object[key] = child
      }
      node = object
      return true

    case .index(let index):
      guard var array = node as? [Any], array.indices.contains(index) else { return false }
      if rest.isEmpty {
        if let value = value {
          array[index] = value
        } else {
          array.remove(at: index)
        }
      } else {
        var child = array[index]
        guard update(&child, at: rest, with: value) else { return false }
        array[index] = child
      }
      node = array
      return true
    }
  }
}
