import XCTest

/// A scan sees the same network many times - once per band, once per mesh node - and the user
/// must see it once, at its best signal. An SSID must also never escape its quotes into a shell:
/// the name comes off the air, chosen by whoever is broadcasting, and goes straight into a
/// `networksetup` command line.
final class WifiScanTests: XCTestCase {

  private func result(_ ssid: String?, _ rssi: Int, _ security: WifiSecurity = .personal)
    -> WifiScan.ScanResult
  {
    WifiScan.ScanResult(ssid: ssid, rssiValue: rssi, security: security)
  }

  // MARK: - Collapsing the scan

  func testTheSameNetworkOnTwoBandsIsOneRowAtItsBestSignal() {
    let networks = WifiScan.dedupe(
      [result("Home", -70), result("Home", -45)], currentSSID: nil)

    XCTAssertEqual(networks.count, 1)
    XCTAssertEqual(networks.first?.rssi, -45, "the 5GHz radio the user would actually join")
  }

  func testTheBestSignalWinsWhicheverOrderTheScanReturnsThemIn() {
    // A scan is a Set, so the iteration order is not stable between runs. If the collapse were
    // order-dependent the signal shown would flicker between bands on every refresh.
    let ascending = WifiScan.dedupe(
      [result("Home", -80), result("Home", -60), result("Home", -40)], currentSSID: nil)
    let descending = WifiScan.dedupe(
      [result("Home", -40), result("Home", -60), result("Home", -80)], currentSSID: nil)

    XCTAssertEqual(ascending.first?.rssi, -40)
    XCTAssertEqual(descending.first?.rssi, -40)
  }

  func testDistinctNetworksAreAllKept() {
    let networks = WifiScan.dedupe(
      [result("Home", -50), result("Office", -60), result("Cafe", -70)], currentSSID: nil)

    XCTAssertEqual(networks.map { $0.ssid }, ["Home", "Office", "Cafe"], "strongest first")
  }

  func testAnEmptyScanIsAnEmptyList() {
    XCTAssertEqual(WifiScan.dedupe([], currentSSID: "Home"), [])
  }

  // MARK: - Networks with no name

  func testARedactedNetworkIsDroppedRatherThanShownUnnamed() {
    // macOS redacts the SSID when the app is not authorized for Location Services. An unnamed row
    // cannot be identified or joined, so it is worse than absent.
    let networks = WifiScan.dedupe(
      [result(nil, -40), result("Home", -70), result("", -30)], currentSSID: nil)

    XCTAssertEqual(networks.map { $0.ssid }, ["Home"])
  }

  // MARK: - Ordering

  func testTheConnectedNetworkSortsFirstEvenOnAWeakSignal() {
    let networks = WifiScan.dedupe(
      [result("Strong", -30), result("Home", -85), result("Middling", -60)],
      currentSSID: "Home")

    XCTAssertEqual(networks.map { $0.ssid }, ["Home", "Strong", "Middling"])
    XCTAssertTrue(networks.first?.isCurrent == true)
  }

  func testEverythingElseSortsByDescendingSignal() {
    let networks = WifiScan.dedupe(
      [result("C", -80), result("A", -40), result("B", -60)], currentSSID: nil)

    XCTAssertEqual(networks.map { $0.ssid }, ["A", "B", "C"])
  }

  // MARK: - What each row carries

  func testAKnownNetworkNeedsNoPasswordAndAnUnknownSecuredOneDoes() {
    let networks = WifiScan.dedupe(
      [result("Saved", -50, .personal), result("New", -55, .personal),
        result("Open", -60, .none)],
      currentSSID: nil, knownSSIDs: ["Saved"])
    let byName = Dictionary(uniqueKeysWithValues: networks.map { ($0.ssid, $0) })

    XCTAssertFalse(byName["Saved"]!.needsPassword, "macOS already has the passphrase")
    XCTAssertTrue(byName["New"]!.needsPassword)
    XCTAssertFalse(byName["Open"]!.needsPassword, "an open network has none to give")
  }

  func testTheStrongestDuplicateCarriesItsOwnSecurity() {
    let networks = WifiScan.dedupe(
      [result("Guest", -70, .personal), result("Guest", -40, .enterprise)], currentSSID: nil)

    XCTAssertEqual(networks.first?.security, .enterprise)
    XCTAssertTrue(networks.first?.security.isEnterprise == true)
  }

  // MARK: - Signal bars

  func testEachBarBoundary() {
    // The buckets are closed at the top: -50 is four bars, -50.000…1 would be three.
    XCTAssertEqual(WifiNetwork.probe(rssi: -30).signalBars, 4)
    XCTAssertEqual(WifiNetwork.probe(rssi: -50).signalBars, 4)
    XCTAssertEqual(WifiNetwork.probe(rssi: -51).signalBars, 3)
    XCTAssertEqual(WifiNetwork.probe(rssi: -60).signalBars, 3)
    XCTAssertEqual(WifiNetwork.probe(rssi: -61).signalBars, 2)
    XCTAssertEqual(WifiNetwork.probe(rssi: -70).signalBars, 2)
    XCTAssertEqual(WifiNetwork.probe(rssi: -71).signalBars, 1)
    XCTAssertEqual(WifiNetwork.probe(rssi: -120).signalBars, 1)
  }

  func testAnImplausibleReadingStillDrawsABar() {
    // An interface that has not associated yet can report 0. A bar count outside 1...4 indexes
    // past the end of the icon list.
    for rssi in [0, 20, -200, Int.min + 1, Int.max] {
      let bars = WifiNetwork.probe(rssi: rssi).signalBars
      XCTAssertTrue((1...4).contains(bars), "rssi \(rssi) produced \(bars) bars")
    }
  }

  // MARK: - Quoting an SSID for the shell

  func testAnOrdinarySSIDIsWrappedInSingleQuotes() {
    XCTAssertEqual(WifiScan.shellQuoted("Home"), "'Home'")
  }

  func testSpacesAndMetacharactersStayInsideTheQuotes() {
    XCTAssertEqual(WifiScan.shellQuoted("My Wi-Fi $HOME"), "'My Wi-Fi $HOME'")
    XCTAssertEqual(WifiScan.shellQuoted("a;b|c&d"), "'a;b|c&d'")
    XCTAssertEqual(WifiScan.shellQuoted("`whoami`"), "'`whoami`'")
  }

  func testAnSSIDCannotCloseItsOwnQuoteAndRunACommand() {
    // The attack this exists to stop: the SSID is broadcast by whoever is nearby, and it is
    // interpolated into a `networksetup` command line. Verified by running the result through a
    // real shell, because what matters is what zsh does with it, not what the string looks like.
    let hostile = "net'; touch /tmp/a-bar-wifi-injection-probe; echo '"
    let marker = "/tmp/a-bar-wifi-injection-probe"
    try? FileManager.default.removeItem(atPath: marker)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", "printf '%s' \(WifiScan.shellQuoted(hostile))"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let printed = String(
      data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()

    XCTAssertEqual(printed, hostile, "the SSID must arrive as one argument, unchanged")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: marker),
      "the embedded command ran - the quoting failed")
  }

  func testQuotingIsStableForAnEmptyName() {
    XCTAssertEqual(WifiScan.shellQuoted(""), "''")
  }
}

extension WifiNetwork {
  /// A row with only the field the bar bucketing reads, so the boundaries can be checked without
  /// inventing the rest of a network.
  fileprivate static func probe(rssi: Int) -> WifiNetwork {
    WifiNetwork(
      id: "probe", ssid: "probe", rssi: rssi, security: .none, isCurrent: false, isKnown: false)
  }
}
