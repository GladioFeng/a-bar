import XCTest

/// A drag payload is a wire format written in one view and read in another. Anything it cannot
/// parse must be refused outright, because the fallback used to be "treat it as a widget name",
/// which turned a malformed drag into a silently dropped one.
final class WidgetDragPayloadTests: XCTestCase {

  // MARK: - Round trips

  func testAPlacedWidgetRoundTrips() {
    let id = UUID()

    XCTAssertEqual(WidgetDragPayload(WidgetDragPayload.instance(id).encoded), .instance(id))
  }

  func testACustomWidgetRoundTrips() {
    XCTAssertEqual(WidgetDragPayload(WidgetDragPayload.userWidget(3).encoded), .userWidget(3))
  }

  func testEveryBuiltInWidgetRoundTrips() {
    // The catalog form is just the raw value, so a widget whose raw value gained a prefix
    // collision would start decoding as something else.
    for identifier in WidgetIdentifier.allCases {
      let payload = WidgetDragPayload.catalog(identifier)

      XCTAssertEqual(WidgetDragPayload(payload.encoded), .catalog(identifier), identifier.rawValue)
    }
  }

  // MARK: - The encoded shapes the two sides agreed on

  func testTheEncodedFormsAreTheOnesTheOtherViewWrites() {
    let id = UUID()

    XCTAssertEqual(WidgetDragPayload.instance(id).encoded, "widget:\(id.uuidString)")
    XCTAssertEqual(WidgetDragPayload.userWidget(2).encoded, "userWidget:2")
    XCTAssertEqual(WidgetDragPayload.catalog(.cpu).encoded, "cpu")
  }

  func testACustomWidgetPayloadIsNotMistakenForAPlacedOne() {
    // "userWidget:" does not begin with "widget:", but the two prefixes are close enough that
    // a sloppier check would confuse them.
    XCTAssertEqual(WidgetDragPayload("userWidget:0"), .userWidget(0))
  }

  // MARK: - Anything else is refused

  func testAMalformedIdentifierIsRefusedRatherThanTreatedAsAWidgetName() {
    XCTAssertNil(WidgetDragPayload("widget:not-a-uuid"))
    XCTAssertNil(WidgetDragPayload("widget:"))
  }

  func testAMalformedCustomWidgetIndexIsRefused() {
    XCTAssertNil(WidgetDragPayload("userWidget:abc"))
    XCTAssertNil(WidgetDragPayload("userWidget:"))
  }

  func testAnUnknownWidgetNameIsRefused() {
    XCTAssertNil(WidgetDragPayload("not-a-widget"))
    XCTAssertNil(WidgetDragPayload(""))
  }

  // MARK: - What the drop should add

  func testAPlacedWidgetAddsNothingBecauseItIsBeingMoved() {
    XCTAssertNil(WidgetDragPayload.instance(UUID()).newInstance)
  }

  func testACatalogPayloadAddsThatWidget() {
    let instance = WidgetDragPayload.catalog(.battery).newInstance

    XCTAssertEqual(instance?.identifier, .battery)
    XCTAssertNil(instance?.userWidgetIndex)
    XCTAssertTrue(instance?.enabled ?? false, "a freshly placed widget is on")
  }

  func testACustomWidgetPayloadCarriesItsIndex() {
    let instance = WidgetDragPayload.userWidget(4).newInstance

    XCTAssertEqual(instance?.identifier, .userWidget)
    XCTAssertEqual(instance?.userWidgetIndex, 4)
  }

  func testEachDropCreatesADistinctWidget() {
    // Dropping the same palette entry twice must give two widgets, not one shared identity.
    let first = WidgetDragPayload.catalog(.cpu).newInstance
    let second = WidgetDragPayload.catalog(.cpu).newInstance

    XCTAssertNotEqual(first?.id, second?.id)
  }
}
