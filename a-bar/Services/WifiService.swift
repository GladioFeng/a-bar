import Combine
import CoreLocation
import CoreWLAN
import Foundation

/// Wi-Fi power state, current association and nearby networks.
///
/// Two sources are merged:
/// - CoreWLAN (in-process, free): power state, current SSID/RSSI/security, the scan
///   cache and the blocking scan. Refreshed instantly through `CWWiFiClient` events
///   rather than polled.
/// - `networksetup -setairportpower` (forks a process): the power toggle only.
///   `CWInterface.setPower` can require authorization, so the shell path that the
///   widget already relied on is kept for the one action where it matters.
///
/// Location Services is load-bearing here, not cosmetic: macOS redacts every SSID —
/// through CoreWLAN, `ipconfig getsummary` and `system_profiler` alike — for apps that
/// are not authorized. Without the grant the service can still report power state and
/// disconnect, but it can never name a network.
///
/// Threading: `CWInterface` reads are cheap and happen on the main thread. Scanning and
/// association block for seconds, so they run on `workQueue` against an interface
/// re-resolved there. `CWEventDelegate` callbacks arrive on an internal CoreWLAN queue
/// and are hopped to main before touching published state.
final class WifiService: ObservableObject {
  static let shared = WifiService()

  @Published private(set) var info = WifiInfo()
  /// SSIDs with a join/disconnect request in flight.
  @Published private(set) var pendingSSIDs: Set<String> = []
  /// Last association failure, surfaced in the popover and cleared on the next attempt.
  @Published private(set) var lastError: String?

  private let client = CWWiFiClient.shared()
  private let location = WifiLocationAuthorization()

  private var refreshTimer: Timer?
  private var isPopoverOpen = false
  /// SSIDs macOS already has credentials for, so a click can join them straight away
  /// instead of asking for a passphrase the keychain already holds.
  private var knownSSIDs: Set<String> = []
  private var isScanning = false
  private var lastScanDate: Date?
  private var cancellables = Set<AnyCancellable>()

  private let settingsManager = SettingsManager.shared
  private let workQueue = DispatchQueue(label: "com.a-bar.wifi", qos: .userInitiated)

  private lazy var observer = WifiEventObserver { [weak self] in
    self?.refreshState()
  }

  private var settings: WifiWidgetSettings {
    settingsManager.settings.widgets.wifi
  }

  private init() {
    location.$isAuthorized
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        // The grant unredacts SSIDs, so everything on screen is stale the moment it
        // lands — including a scan whose results all had nil names.
        self?.refreshState()
        self?.scanIfNeeded(force: true)
      }
      .store(in: &cancellables)
  }

  // MARK: - Lifecycle

  func start() {
    refreshState()
    startMonitoring()
    startTimer()
  }

  func stop() {
    refreshTimer?.invalidate()
    refreshTimer = nil
    try? client.stopMonitoringAllEvents()
    client.delegate = nil
  }

  func refresh() {
    refreshState()
    scanIfNeeded(force: true)
  }

  /// Events carry the state changes; this only exists so a missed event cannot leave
  /// the bar wrong indefinitely. Deliberately slow — it is a safety net, not the
  /// mechanism.
  private func startTimer() {
    refreshTimer?.invalidate()
    refreshTimer = Timer.scheduledTimer(
      withTimeInterval: settings.refreshInterval, repeats: true
    ) { [weak self] _ in
      self?.refreshState()
    }
  }

  private func startMonitoring() {
    client.delegate = observer
    for event in [
      CWEventType.powerDidChange,
      .ssidDidChange,
      .linkDidChange,
      .scanCacheUpdated,
    ] {
      do {
        try client.startMonitoringEvent(with: event)
      } catch {
        print("Wi-Fi: could not monitor \(event.rawValue): \(error)")
      }
    }
  }

  // MARK: - Interface resolution

  /// The configured device when the user set one, otherwise the first Wi-Fi interface
  /// macOS reports. Not every Mac puts Wi-Fi on en0, and the old hardcoded default
  /// silently showed nothing on the ones that don't.
  private var interfaceName: String? {
    let configured = settings.networkDevice.trimmingCharacters(in: .whitespaces)
    if !configured.isEmpty { return configured }
    return client.interfaceNames()?.first
  }

  private var currentInterface: CWInterface? {
    guard let name = interfaceName else { return nil }
    return client.interface(withName: name)
  }

  // MARK: - CoreWLAN snapshot (main thread)

  /// Read power state and the current association straight from CoreWLAN. These are
  /// in-process property reads, unlike the scan, so they are safe on the main thread.
  func refreshState() {
    var next = info
    next.locationAuthorized = location.isAuthorized

    guard let interface = currentInterface else {
      next.hasInterface = false
      next.isPoweredOn = false
      next.isAssociated = false
      next.ssid = nil
      next.networks = []
      publish(next)
      return
    }

    next.hasInterface = true
    next.isPoweredOn = interface.powerOn()

    if next.isPoweredOn {
      // `interfaceMode` is not redacted, so association is known even when the name is
      // withheld. Deriving "connected" from `ssid != nil` would report a connected Mac
      // as disconnected whenever Location Services is denied.
      next.isAssociated = interface.interfaceMode() == .station
      next.ssid = interface.ssid()
    } else {
      // Nothing is associated and nothing is in range while the radio is down.
      next.isAssociated = false
      next.ssid = nil
      next.networks = []
    }

    publish(next)
  }

  /// Avoid republishing identical state: the timer and the event stream would otherwise
  /// re-render every bar on every display on each tick.
  private func publish(_ next: WifiInfo) {
    if info != next {
      info = next
    }
  }

  // MARK: - Scanning

  /// Scan for nearby networks.
  ///
  /// `scanForNetworks` blocks for the duration of the scan — seconds, on a busy band —
  /// so it never runs on the main thread. It is also demand-driven rather than
  /// timer-driven: an idle bar with a closed popover never scans, and macOS rate-limits
  /// repeated scans anyway.
  func scanIfNeeded(force: Bool = false) {
    guard info.hasInterface, info.isPoweredOn else { return }
    guard force || isPopoverOpen else { return }
    guard !isScanning else { return }

    // macOS throttles back-to-back scans and returns stale results for them, so honour
    // a floor between active scans even when the caller forces one.
    if let last = lastScanDate, Date().timeIntervalSince(last) < settings.scanInterval {
      readCachedScanResults()
      return
    }

    isScanning = true
    lastScanDate = Date()
    let name = interfaceName

    workQueue.async { [weak self] in
      // Re-resolve on this queue rather than capturing the main-thread interface.
      let interface = name.flatMap { CWWiFiClient.shared().interface(withName: $0) }
      let networks = (try? interface?.scanForNetworks(withSSID: nil, includeHidden: false))

      DispatchQueue.main.async {
        guard let self = self else { return }
        self.isScanning = false
        guard let networks = networks else {
          self.readCachedScanResults()
          return
        }
        var next = self.info
        next.networks = WifiService.dedupe(
          networks, currentSSID: self.info.ssid, knownSSIDs: self.knownSSIDs)
        self.publish(next)
      }
    }
  }

  /// Paint whatever CoreWLAN already knows, instantly. Used while a real scan is in
  /// flight, and when the throttle rejects one.
  private func readCachedScanResults() {
    guard let cached = currentInterface?.cachedScanResults() else { return }
    var next = info
    next.networks = WifiService.dedupe(cached, currentSSID: info.ssid, knownSSIDs: knownSSIDs)
    publish(next)
  }

  /// A scan returns one `CWNetwork` per BSSID, so a single network shows up once per
  /// band and once per mesh node. Collapse by SSID, keeping the strongest signal.
  ///
  /// Networks with a nil SSID are dropped: those are the ones macOS redacted because
  /// the app is not authorized for Location Services, and an unnamed row is useless.
  static func dedupe(
    _ networks: Set<CWNetwork>, currentSSID: String?, knownSSIDs: Set<String> = []
  ) -> [WifiNetwork] {
    var strongest: [String: WifiNetwork] = [:]

    for network in networks {
      guard let ssid = network.ssid, !ssid.isEmpty else { continue }
      let candidate = WifiNetwork(
        id: ssid,
        ssid: ssid,
        rssi: network.rssiValue,
        security: WifiSecurity(network),
        isCurrent: ssid == currentSSID,
        isKnown: knownSSIDs.contains(ssid)
      )
      if let existing = strongest[ssid], existing.rssi >= candidate.rssi { continue }
      strongest[ssid] = candidate
    }

    return strongest.values.sorted {
      $0.isCurrent == $1.isCurrent
        ? $0.rssi > $1.rssi
        : $0.isCurrent
    }
  }

  // MARK: - Popover-driven cadence

  func setPopoverOpen(_ open: Bool) {
    isPopoverOpen = open
    guard open else { return }
    // Asking for the grant here rather than at launch means a user who never opens the
    // popover never sees the prompt.
    location.requestIfNeeded()
    refreshKnownNetworks()
    refreshState()
    readCachedScanResults()
    scanIfNeeded()
  }

  /// Read the preferred-networks list. Unlike SSIDs from a scan, `networksetup` never
  /// redacts these, so this works even when Location Services is denied.
  private func refreshKnownNetworks() {
    guard let device = interfaceName else { return }
    Task {
      let output = try? await ShellExecutor.run(
        "networksetup -listpreferredwirelessnetworks \(WifiService.shellQuoted(device))")
      guard let output = output else { return }
      // First line is the "Preferred networks on enN:" header; the rest are tab-indented.
      let names =
        output
        .split(separator: "\n")
        .dropFirst()
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      await MainActor.run {
        self.knownSSIDs = Set(names)
        self.readCachedScanResults()
      }
    }
  }

  // MARK: - Actions

  /// Toggle the radio through `networksetup`, which needs no admin rights and is the
  /// path this widget already used. `CWInterface.setPower` can require authorization.
  func togglePower() {
    guard let device = interfaceName else { return }
    let turnOn = !info.isPoweredOn

    Task {
      _ = try? await ShellExecutor.run(
        "networksetup -setairportpower \(WifiService.shellQuoted(device)) "
          + (turnOn ? "on" : "off"))
      await MainActor.run {
        self.refreshState()
        if turnOn {
          // The radio needs a beat before it can see anything.
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshState()
            self?.scanIfNeeded(force: true)
          }
        }
      }
    }
  }

  /// Join a network.
  ///
  /// `associate(to:password:)` blocks for the duration of the association, so it runs on
  /// `workQueue`. It is also the reason this does not shell out to
  /// `networksetup -setairportnetwork <ssid> <password>`: a password passed as a shell
  /// argument is visible in `ps` to every other process on the machine. CoreWLAN keeps
  /// it out of argv entirely.
  func join(_ network: WifiNetwork, password: String? = nil) {
    guard !pendingSSIDs.contains(network.id) else { return }
    guard !network.security.isEnterprise else {
      // Enterprise needs an identity or username this popover does not collect.
      openNetworkSettings()
      return
    }

    let ssid = network.ssid
    lastError = nil
    pendingSSIDs.insert(ssid)
    startPendingWatchdog(for: ssid)

    let name = interfaceName
    workQueue.async { [weak self] in
      let interface = name.flatMap { CWWiFiClient.shared().interface(withName: $0) }
      var failure: String?

      // Re-resolve the CWNetwork on this queue: `associate` wants a live scan object,
      // not the value type the view handed us. Try the cache first — a directed scan
      // blocks for seconds, and the popover has almost always just scanned.
      var target = interface?.cachedScanResults()?.first { $0.ssid == ssid }
      if target == nil {
        target = (try? interface?.scanForNetworks(withSSID: network.ssidData))?
          .first { $0.ssid == ssid }
      }

      if let interface = interface, let target = target {
        do {
          try interface.associate(to: target, password: password)
        } catch {
          failure = error.localizedDescription
        }
      } else {
        failure = "Network '\(ssid)' is no longer in range."
      }

      // Fall back to networksetup for a remembered network, which reads the passphrase
      // from the keychain. No password argument, so this stays out of argv too.
      if failure != nil, password == nil, let device = name {
        let output = ShellExecutor.runSync(
          "networksetup -setairportnetwork \(WifiService.shellQuoted(device)) "
            + WifiService.shellQuoted(ssid))
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          failure = nil
        }
      }

      DispatchQueue.main.async {
        guard let self = self else { return }
        self.pendingSSIDs.remove(ssid)
        self.lastError = failure
        if let failure = failure {
          print("Wi-Fi: join failed for \(ssid): \(failure)")
        }
        self.refreshState()
      }
    }
  }

  /// Drop the current association.
  ///
  /// This is not "forget": the network stays in the preferred list, so macOS is free to
  /// rejoin it moments later. The popover says as much rather than pretending otherwise.
  func disconnect() {
    guard info.isAssociated else { return }
    // Key the spinner by name when we have one; without Location Services we do not,
    // and disconnecting must still work.
    let ssid = info.ssid ?? WifiService.unnamedCurrentNetwork
    guard !pendingSSIDs.contains(ssid) else { return }
    lastError = nil
    pendingSSIDs.insert(ssid)
    startPendingWatchdog(for: ssid)

    let name = interfaceName
    workQueue.async { [weak self] in
      name.flatMap { CWWiFiClient.shared().interface(withName: $0) }?.disassociate()
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.pendingSSIDs.remove(ssid)
        self.refreshState()
      }
    }
  }

  /// Never let a row's spinner stick forever if an association hangs past the CoreWLAN
  /// timeout.
  private func startPendingWatchdog(for ssid: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      self?.pendingSSIDs.remove(ssid)
    }
  }

  /// Stand-in key for the connected network when macOS will not name it.
  static let unnamedCurrentNetwork = "\u{0}a-bar.current"

  func openNetworkSettings() {
    Task {
      _ = try? await ShellExecutor.run("open /System/Library/PreferencePanes/Network.prefPane/")
    }
  }

  func openLocationSettings() {
    Task {
      _ = try? await ShellExecutor.run(
        "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices'")
    }
  }

  /// Single-quote for the shell, escaping embedded quotes. SSIDs can contain spaces and
  /// shell metacharacters.
  static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

/// Obj-C shim for `CWEventDelegate`, which requires a real NSObject. Mirrors the
/// IOBluetooth observer in `BluetoothService`.
///
/// CoreWLAN delivers these on its own queue, so the callback hops to main before the
/// service touches published state.
private final class WifiEventObserver: NSObject, CWEventDelegate {
  private let onChange: () -> Void

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
    super.init()
  }

  private func notify() {
    DispatchQueue.main.async { [weak self] in
      self?.onChange()
    }
  }

  func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { notify() }
  func ssidDidChangeForWiFiInterface(withName interfaceName: String) { notify() }
  func linkDidChangeForWiFiInterface(withName interfaceName: String) { notify() }
  func scanCacheUpdatedForWiFiInterface(withName interfaceName: String) { notify() }
}

// MARK: - Location authorization

/// Thin `CLLocationManager` wrapper whose only job is to hold the Location Services
/// grant that CoreWLAN checks before it will name a network.
///
/// It never starts location updates — authorization alone unredacts SSIDs, and reading
/// a position would be gratuitous.
final class WifiLocationAuthorization: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var isAuthorized = false

  private let manager = CLLocationManager()
  private var hasRequested = false

  override init() {
    super.init()
    manager.delegate = self
    isAuthorized = WifiLocationAuthorization.isGranted(manager.authorizationStatus)
  }

  /// Ask once per launch, and only when something actually needs a network name.
  func requestIfNeeded() {
    guard !hasRequested else { return }
    hasRequested = true

    guard !isAuthorized else { return }

    // `locationServicesEnabled()` blocks, so it must not be called on the main thread.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let enabled = CLLocationManager.locationServicesEnabled()
      DispatchQueue.main.async {
        guard enabled else { return }
        self?.manager.requestWhenInUseAuthorization()
      }
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let granted = WifiLocationAuthorization.isGranted(manager.authorizationStatus)
    DispatchQueue.main.async { [weak self] in
      self?.isAuthorized = granted
    }
  }

  /// macOS resolves a when-in-use request to `.authorizedAlways`; `.authorized` is the
  /// deprecated spelling still returned on older systems.
  private static func isGranted(_ status: CLAuthorizationStatus) -> Bool {
    switch status {
    case .authorizedAlways, .authorized:
      return true
    default:
      return false
    }
  }
}

// MARK: - Models

/// Aggregate Wi-Fi state published to the widgets.
struct WifiInfo: Equatable {
  /// A Wi-Fi interface exists on this Mac.
  var hasInterface: Bool = false
  /// The radio is powered on.
  var isPoweredOn: Bool = false
  /// Associated with a network. Distinct from `ssid` being non-nil: macOS redacts the
  /// name without Location Services but still reports the interface mode, so this stays
  /// truthful where the name cannot.
  var isAssociated: Bool = false
  /// Current network name. Nil when unassociated — or when Location Services is denied,
  /// since macOS redacts the name in that case.
  var ssid: String?
  /// Nearby networks, deduped by SSID, current first then by signal strength.
  ///
  /// The connected network's own signal lives on its row here rather than on this
  /// struct: a live RSSI reading drifts by a dBm every few seconds, and holding it in
  /// the published snapshot would defeat the equality check in `publish` and re-render
  /// every bar on every display on each tick.
  var networks: [WifiNetwork] = []
  /// Whether the app may read network names at all.
  var locationAuthorized: Bool = false

  var isConnected: Bool { isAssociated }
}

/// One nearby network, collapsed from every BSSID advertising that SSID.
struct WifiNetwork: Identifiable, Equatable {
  /// The SSID doubles as the identity: rows are per network, not per radio.
  let id: String
  let ssid: String
  let rssi: Int
  let security: WifiSecurity
  let isCurrent: Bool
  /// Already in the preferred-networks list, so macOS has its passphrase.
  let isKnown: Bool

  var ssidData: Data? { ssid.data(using: .utf8) }

  /// A passphrase must be collected only for a secured network we have never joined.
  var needsPassword: Bool { security.isSecured && !isKnown }

  /// Signal strength bucketed to four bars, on the usual dBm boundaries.
  var signalBars: Int {
    switch rssi {
    case (-50)...: return 4
    case (-60)..<(-50): return 3
    case (-70)..<(-60): return 2
    default: return 1
    }
  }
}

/// Coarse security class. CoreWLAN distinguishes far more cases than the popover needs;
/// what matters here is whether a passphrase is required and whether joining is even
/// possible without an enterprise identity.
enum WifiSecurity: Equatable {
  case none
  case personal
  case enterprise
  case unknown

  var isSecured: Bool { self != .none }
  var isEnterprise: Bool { self == .enterprise }

  init(_ security: CWSecurity) {
    switch security {
    case .none:
      self = .none
    case .WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal,
      .wpa3Personal, .wpa3Transition, .OWE, .oweTransition:
      self = .personal
    case .dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise,
      .enterprise, .wpa3Enterprise:
      self = .enterprise
    default:
      self = .unknown
    }
  }

  /// Scan results report support per security type rather than a single value, so the
  /// strongest match wins: enterprise first, then personal, then open.
  init(_ network: CWNetwork) {
    let enterprise: [CWSecurity] = [
      .dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise,
      .wpa3Enterprise,
    ]
    let personal: [CWSecurity] = [
      .WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal, .wpa3Personal,
      .wpa3Transition, .OWE, .oweTransition,
    ]

    if enterprise.contains(where: network.supportsSecurity) {
      self = .enterprise
    } else if personal.contains(where: network.supportsSecurity) {
      self = .personal
    } else if network.supportsSecurity(.none) {
      self = .none
    } else {
      self = .unknown
    }
  }
}
