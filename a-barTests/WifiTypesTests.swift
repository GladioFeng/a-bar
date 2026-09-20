import XCTest

/// What the Wi-Fi popover offers to do with a row is decided entirely by these derived
/// properties: whether to prompt for a passphrase, how many bars to draw, and whether the
/// name on screen can be trusted at all.
final class WifiTypesTests: XCTestCase {

    private func network(
        _ ssid: String = "Home",
        rssi: Int = -55,
        security: WifiSecurity = .personal,
        current: Bool = false,
        known: Bool = false
    ) -> WifiNetwork {
        WifiNetwork(id: ssid, ssid: ssid, rssi: rssi, security: security,
                    isCurrent: current, isKnown: known)
    }

    // MARK: - Joining

    func testASecuredNetworkNeverJoinedNeedsAPassword() {
        XCTAssertTrue(network(security: .personal, known: false).needsPassword)
    }

    func testASecuredNetworkAlreadyKnownDoesNot() {
        // macOS holds the passphrase, so prompting again would be asking for nothing.
        XCTAssertFalse(network(security: .personal, known: true).needsPassword)
    }

    func testAnOpenNetworkNeverNeedsAPassword() {
        XCTAssertFalse(network(security: .none, known: false).needsPassword)
    }

    func testSecurityClassesReportWhetherTheyAreSecuredAndEnterprise() {
        XCTAssertFalse(WifiSecurity.none.isSecured)
        XCTAssertTrue(WifiSecurity.personal.isSecured)
        XCTAssertTrue(WifiSecurity.enterprise.isSecured)
        XCTAssertTrue(WifiSecurity.unknown.isSecured,
                      "an unrecognized class is treated as secured rather than open")

        XCTAssertTrue(WifiSecurity.enterprise.isEnterprise)
        for other: WifiSecurity in [.none, .personal, .unknown] {
            XCTAssertFalse(other.isEnterprise)
        }
    }

    // MARK: - Signal strength

    func testSignalBarsBucketOnTheUsualBoundaries() {
        let cases: [(Int, Int)] = [
            (-10, 4), (-50, 4),
            (-51, 3), (-60, 3),
            (-61, 2), (-70, 2),
            (-71, 1), (-120, 1),
        ]
        for (rssi, expected) in cases {
            XCTAssertEqual(network(rssi: rssi).signalBars, expected, "\(rssi) dBm")
        }
    }

    func testSignalBarsNeverFallBelowOne() {
        XCTAssertEqual(network(rssi: Int.min).signalBars, 1,
                       "a row with zero bars would read as no row at all")
    }

    // MARK: - SSID as data

    func testSsidDataIsTheUtf8Encoding() {
        XCTAssertEqual(network("Café").ssidData, "Café".data(using: .utf8))
    }

    func testAnEmptySsidStillEncodes() {
        XCTAssertEqual(network("").ssidData, Data())
    }

    // MARK: - WifiInfo

    func testAFreshInfoIsDisconnectedAndUnauthorized() {
        let info = WifiInfo()

        XCTAssertFalse(info.hasInterface)
        XCTAssertFalse(info.isConnected)
        XCTAssertNil(info.ssid)
        XCTAssertFalse(info.locationAuthorized)
    }

    func testConnectionFollowsAssociationRatherThanTheName() {
        // Without Location Services macOS redacts the SSID but still reports the mode, so a
        // nil name must not read as "not connected".
        let redacted = WifiInfo(isPoweredOn: true, isAssociated: true, ssid: nil)

        XCTAssertTrue(redacted.isConnected)
    }

    func testANameWithoutAssociationIsNotAConnection() {
        XCTAssertFalse(WifiInfo(isAssociated: false, ssid: "Home").isConnected)
    }
}
