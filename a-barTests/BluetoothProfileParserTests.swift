import XCTest

/// Battery level arrives as an integer, a double, or a localized percentage string depending on
/// the device and the macOS version; all three are the same number. This is the only source of
/// Bluetooth battery there is - IOBluetooth does not expose it at all - so a device this cannot
/// read shows no battery, and a parse this gives up on shows none for any device.
final class BluetoothProfileParserTests: XCTestCase {

  /// A `system_profiler SPBluetoothDataType -json` document, built from device entries.
  private func profile(connected: String = "", notConnected: String = "") -> Data {
    var lists: [String] = []
    if !connected.isEmpty { lists.append("\"device_connected\":[\(connected)]") }
    if !notConnected.isEmpty { lists.append("\"device_not_connected\":[\(notConnected)]") }
    return Data("{\"SPBluetoothDataType\":[{\(lists.joined(separator: ","))}]}".utf8)
  }

  private func device(_ name: String, _ properties: String) -> String {
    "{\"\(name)\":{\(properties)}}"
  }

  // MARK: - The three shapes a battery level arrives in

  func testAnIntegerPercentage() {
    XCTAssertEqual(BluetoothProfileParser.batteryPercent(85), 85)
    XCTAssertEqual(BluetoothProfileParser.batteryPercent(0), 0)
    XCTAssertEqual(BluetoothProfileParser.batteryPercent(100), 100)
  }

  func testADoublePercentageIsRoundedRatherThanTruncated() {
    XCTAssertEqual(BluetoothProfileParser.batteryPercent(84.6), 85)
    XCTAssertEqual(BluetoothProfileParser.batteryPercent(84.4), 84)
  }

  func testALocalizedPercentageStringWithANonBreakingSpace() {
    // The observed value is "100\u{00A0}%". Trimming a fixed character set leaves the U+00A0 in
    // place, `Int(_:)` then returns nil, and battery silently never renders for that device.
    XCTAssertEqual(BluetoothProfileParser.batteryPercent("100\u{00A0}%"), 100)
    XCTAssertEqual(BluetoothProfileParser.batteryPercent("85 %"), 85)
    XCTAssertEqual(BluetoothProfileParser.batteryPercent("85%"), 85)
    XCTAssertEqual(BluetoothProfileParser.batteryPercent("%85"), 85)
  }

  func testAValueWithNoDigitsIsUnknownRatherThanZero() {
    // Zero would render as an empty battery on a device that simply does not report one.
    XCTAssertNil(BluetoothProfileParser.batteryPercent("--"))
    XCTAssertNil(BluetoothProfileParser.batteryPercent(""))
    XCTAssertNil(BluetoothProfileParser.batteryPercent(nil))
    XCTAssertNil(BluetoothProfileParser.batteryPercent(["85"]))
  }

  // MARK: - The merge key

  func testTheTwoAddressSpellingsNormalizeToTheSameKey() {
    // IOBluetooth reports "ac-bf-71-09-96-af" and system_profiler "AC:BF:71:09:96:AF". Comparing
    // them directly always fails, and battery never appears for any device.
    XCTAssertEqual(
      BluetoothProfileParser.normalizedAddress("AC:BF:71:09:96:AF"),
      BluetoothProfileParser.normalizedAddress("ac-bf-71-09-96-af"))
    XCTAssertEqual(BluetoothProfileParser.normalizedAddress("AC:BF:71:09:96:AF"), "acbf710996af")
  }

  func testNormalizingIsIdempotent() {
    let once = BluetoothProfileParser.normalizedAddress("AC:BF:71:09:96:AF")

    XCTAssertEqual(BluetoothProfileParser.normalizedAddress(once), once)
  }

  // MARK: - Walking the document

  func testASingleBatteryHeadsetReportsOnlyItsMainLevel() {
    let parsed = BluetoothProfileParser.parse(profile(connected: device("Beats", """
      "device_address":"AC:BF:71:09:96:AF","device_batteryLevelMain":"70\u{00A0}%"
      """)))

    let levels = parsed?.battery["acbf710996af"]
    XCTAssertEqual(levels?.main, 70)
    XCTAssertNil(levels?.left)
    XCTAssertEqual(levels?.lowest, 70)
  }

  func testAirPodsReportLeftRightAndCaseSeparately() {
    let parsed = BluetoothProfileParser.parse(profile(connected: device("AirPods Pro", """
      "device_address":"11:22:33:44:55:66","device_batteryLevelLeft":"80\u{00A0}%",\
      "device_batteryLevelRight":"75\u{00A0}%","device_batteryLevelCase":"45\u{00A0}%"
      """)))

    let levels = parsed?.battery["112233445566"]
    XCTAssertEqual(levels?.left, 80)
    XCTAssertEqual(levels?.right, 75)
    XCTAssertEqual(levels?.caseLevel, 45)
    XCTAssertNil(levels?.main)
    XCTAssertEqual(levels?.lowest, 45, "the tint follows the worst of them")
  }

  func testAnUnfamiliarBatterySuffixLandsOnMainRatherThanBeingDropped() {
    // The scan is by prefix precisely so a renamed or added suffix degrades to something rather
    // than to nothing.
    let parsed = BluetoothProfileParser.parse(profile(connected: device("Future", """
      "device_address":"01:02:03:04:05:06","device_batteryLevelSomethingNew":"60 %"
      """)))

    XCTAssertEqual(parsed?.battery["010203040506"]?.main, 60)
  }

  func testDisconnectedDevicesAreWalkedTooAndMinorTypesAreCollected() {
    let parsed = BluetoothProfileParser.parse(profile(
      connected: device("Mouse", """
        "device_address":"AA:AA:AA:AA:AA:AA","device_minorType":"Mouse",\
        "device_batteryLevelMain":"20 %"
        """),
      notConnected: device("Keyboard", """
        "device_address":"BB:BB:BB:BB:BB:BB","device_minorType":"Keyboard"
        """)))

    XCTAssertEqual(parsed?.battery["aaaaaaaaaaaa"]?.main, 20)
    XCTAssertEqual(parsed?.minorTypes["aaaaaaaaaaaa"], "Mouse")
    XCTAssertEqual(parsed?.minorTypes["bbbbbbbbbbbb"], "Keyboard",
      "a disconnected device still needs its icon")
  }

  func testADeviceWithNoBatteryIsAbsentRatherThanPresentAndEmpty() {
    // An empty `BluetoothBatteryLevels` would render as a battery pill with nothing in it.
    let parsed = BluetoothProfileParser.parse(profile(connected: device("Speaker", """
      "device_address":"CC:CC:CC:CC:CC:CC","device_minorType":"Speaker"
      """)))

    XCTAssertNil(parsed?.battery["cccccccccccc"])
    XCTAssertEqual(parsed?.minorTypes["cccccccccccc"], "Speaker")
  }

  func testOneUnreadableDeviceDoesNotCostTheOthersTheirBattery() {
    let parsed = BluetoothProfileParser.parse(profile(connected: """
      {"Broken":{"no_address_here":true}},\
      \(device("Good", "\"device_address\":\"DD:DD:DD:DD:DD:DD\",\"device_batteryLevelMain\":90"))
      """))

    XCTAssertEqual(parsed?.battery["dddddddddddd"]?.main, 90)
    XCTAssertEqual(parsed?.battery.count, 1)
  }

  // MARK: - Documents it cannot use

  func testNothingConnectedIsAnEmptyProfileRatherThanAFailure() {
    // `device_connected` is absent entirely when nothing is connected. That is the normal state
    // of a Mac with no devices in range, not an error.
    let parsed = BluetoothProfileParser.parse(profile())

    XCTAssertEqual(parsed, BluetoothProfileParser.ParsedProfile())
  }

  func testOutputThatIsNotTheExpectedDocumentReturnsNil() {
    XCTAssertNil(BluetoothProfileParser.parse(Data("not json at all".utf8)))
    XCTAssertNil(BluetoothProfileParser.parse(Data("{}".utf8)))
    XCTAssertNil(BluetoothProfileParser.parse(Data(#"{"SPBluetoothDataType":[]}"#.utf8)))
    XCTAssertNil(BluetoothProfileParser.parse(Data()))
  }
}
