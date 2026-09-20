import XCTest

/// The byte counters are summed over an allow-list of interfaces. Admitting one too many
/// double-counts traffic already counted on a real interface; admitting one too few makes the
/// graph read zero on a Mac whose only connection is the one that was left out.
final class NetworkInterfacesTests: XCTestCase {

  // MARK: - Interfaces that carry the user's traffic

  func testTheInterfacesEveryMacActuallyUsesAreAdmitted() {
    for name in ["en0", "en1", "en10", "bridge0", "ap1", "awdl0", "llw0"] {
      XCTAssertTrue(
        NetworkInterfaces.isValidDataInterface(name), "\(name) carries traffic and was excluded")
    }
  }

  func testTunnelsAndTetheringAreAdmitted() {
    // A Mac on a VPN sees all of its traffic on utun, and one tethered to an iPhone sees it on
    // pdp_ip. Excluding either leaves the graph flat on exactly the connection being used.
    for name in ["utun0", "utun4", "ipsec0", "pdp_ip0", "ppp0"] {
      XCTAssertTrue(NetworkInterfaces.isValidDataInterface(name), "\(name) was excluded")
    }
  }

  // MARK: - Interfaces that would double-count or invent traffic

  func testLoopbackAndVirtualInterfacesAreExcluded() {
    for name in ["lo0", "gif0", "stf0", "anpi0", "vmenet0", "XHC20"] {
      XCTAssertFalse(
        NetworkInterfaces.isValidDataInterface(name), "\(name) would inflate the reading")
    }
  }

  func testAnEmptyNameIsExcluded() {
    XCTAssertFalse(NetworkInterfaces.isValidDataInterface(""))
  }

  func testTheMatchIsOnThePrefixAndIsCaseSensitive() {
    // The kernel names these in lower case. Matching loosely would let `EN0` through from a
    // source that does not, which is a change nobody would notice until the numbers were wrong.
    XCTAssertTrue(NetworkInterfaces.isValidDataInterface("en0suffix"))
    XCTAssertFalse(NetworkInterfaces.isValidDataInterface("EN0"))
    XCTAssertFalse(NetworkInterfaces.isValidDataInterface("xen0"))
  }
}
