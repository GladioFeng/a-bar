import XCTest

/// `netstat -ibn` lists an interface once per address family - link, inet, inet6 - and every
/// one of those rows carries the same cumulative byte counters for the whole interface.
/// Adding the rows up therefore counts the same traffic two or three times, and since the
/// throughput on the bar is a delta between two readings, the rate shown is inflated by the
/// same factor.
final class NetstatParserTests: XCTestCase {

    func testASingleInterfaceIsSummed() {
        let totals = NetstatParser.totals("en0 1000 500")

        XCTAssertEqual(totals, NetstatParser.Totals(received: 1000, sent: 500))
    }

    func testAnInterfaceListedOncePerAddressFamilyIsCountedOnce() {
        // This is the shape real output has: en0 for <Link#N>, then for inet, then inet6.
        let totals = NetstatParser.totals("""
            en0 2090995330 297058621
            en0 2090995330 297058621
            en0 2090995330 297058621
            """)

        XCTAssertEqual(totals, NetstatParser.Totals(received: 2090995330, sent: 297058621),
                       "three rows, one interface, one set of counters")
    }

    func testSeparateInterfacesAreAddedTogether() {
        let totals = NetstatParser.totals("""
            en0 1000 100
            en1 2000 200
            """)

        XCTAssertEqual(totals, NetstatParser.Totals(received: 3000, sent: 300))
    }

    func testTheHighestReadingForAnInterfaceWins() {
        // Rows are snapshots of the same counter; a lower one is staler, not additional.
        let totals = NetstatParser.totals("""
            en0 900 90
            en0 1000 100
            """)

        XCTAssertEqual(totals, NetstatParser.Totals(received: 1000, sent: 100))
    }

    // MARK: - Which interfaces count

    func testLoopbackIsExcluded() {
        let totals = NetstatParser.totals("""
            lo0 74333126 74333126
            en0 1000 100
            """)

        XCTAssertEqual(totals, NetstatParser.Totals(received: 1000, sent: 100))
    }

    func testTunnelInterfacesThatDoNotCarryUserTrafficAreExcluded() {
        let totals = NetstatParser.totals("""
            gif0* 5 5
            stf0* 5 5
            en0 1000 100
            """)

        XCTAssertEqual(totals, NetstatParser.Totals(received: 1000, sent: 100),
                       "a 6to4 or generic tunnel is not traffic the user sent")
    }

    func testVpnAndBridgeInterfacesAreCountedBecauseTrafficReallyFlowsOverThem() {
        // `NetworkInterfaces.isValidDataInterface` allows these on purpose: a VPN tunnel or
        // an iPhone tether is the connection, not a shadow of one.
        let totals = NetstatParser.totals("""
            utun0 300 30
            bridge0 200 20
            pdp_ip0 100 10
            en0 1000 100
            """)

        XCTAssertEqual(totals, NetstatParser.Totals(received: 1600, sent: 160))
    }

    // MARK: - Malformed input

    func testAShortRowIsSkippedWithoutLosingTheRest() {
        let totals = NetstatParser.totals("""
            en0 1000
            en1 2000 200
            """)

        XCTAssertEqual(totals, NetstatParser.Totals(received: 2000, sent: 200))
    }

    func testANonNumericCounterIsSkipped() {
        let totals = NetstatParser.totals("""
            en0 - -
            en1 2000 200
            """)

        XCTAssertEqual(totals, NetstatParser.Totals(received: 2000, sent: 200))
    }

    func testExtraColumnsAreIgnored() {
        XCTAssertEqual(
            NetstatParser.totals("en0 1000 100 extra stuff"),
            NetstatParser.Totals(received: 1000, sent: 100))
    }

    func testRunsOfSpacesDoNotProduceEmptyColumns() {
        XCTAssertEqual(
            NetstatParser.totals("en0    1000     100"),
            NetstatParser.Totals(received: 1000, sent: 100))
    }

    func testEmptyOutputIsZero() {
        XCTAssertEqual(NetstatParser.totals(""), NetstatParser.Totals())
        XCTAssertEqual(NetstatParser.totals("\n\n"), NetstatParser.Totals())
    }

    func testOutputWithNoUsableInterfaceIsZero() {
        XCTAssertEqual(NetstatParser.totals("lo0 500 500"), NetstatParser.Totals())
    }
}
