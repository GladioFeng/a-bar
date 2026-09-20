import XCTest

/// Repairing yabai's malformed JSON must not alter the data inside it. Every window title in the
/// bar, and every id a click is routed by, comes through here - so a repair that rewrites a value
/// is worse than the malformed output it was written for, because the malformed output at least
/// failed loudly.
final class YabaiJSONSanitizerTests: XCTestCase {

  /// A real `yabai -m query --windows` row, with the fields the app decodes.
  private func window(id: Int, title: String) -> String {
    """
    {"id":\(id),"pid":42,"app":"Safari","title":"\(title)","frame":{"x":0.0000,"y":0.0000,\
    "w":1440.0000,"h":900.0000},"role":"AXWindow","subrole":"AXStandardWindow","display":1,\
    "space":1,"level":0,"layer":"normal","opacity":1.0000,"has-focus":true,"is-visible":true}
    """
  }

  private func decodeWindows(_ json: String) throws -> [YabaiWindow] {
    let sanitized = YabaiJSONSanitizer.sanitize(json)
    return try JSONDecoder().decode([YabaiWindow].self, from: Data(sanitized.utf8))
  }

  // MARK: - The governing property

  func testOutputThatIsAlreadyValidJSONComesBackUnchanged() {
    // Everything the sanitizer still rewrites is invalid JSON before it is touched. That is what
    // makes it safe to run over every query: no reading of a real window can pass through it and
    // come out different.
    let samples = [
      "[]",
      "[" + window(id: 100_000, title: "Budget 100000 EUR") + "]",
      #"{"a":[1,2,3],"b":"x, y, z","c":0.0,"d":-0.00001,"e":1e10}"#,
      #"["[,]","a,,b",",]","\\","\"","\n"]"#,
      #"{"title":"00000"}"#,
    ]

    for sample in samples {
      XCTAssertEqual(
        YabaiJSONSanitizer.sanitize(sample), sample,
        "valid JSON must survive the sanitizer byte for byte")
    }
  }

  // MARK: - Values the old sanitizer corrupted

  func testAWindowTitleContainingAQuoteStillDecodes() throws {
    // The old sanitizer doubled every backslash and then collapsed `\\"` to `"`, which turned an
    // escaped quote inside a title into a bare one. The document stopped parsing, so a single
    // window titled with a quote blanked every yabai widget in the bar.
    let windows = try decodeWindows("[" + window(id: 1, title: #"He said \"hi\""#) + "]")

    XCTAssertEqual(windows.first?.title, #"He said "hi""#)
  }

  func testAWindowTitleContainingAnEscapeKeepsIt() throws {
    // The same doubling turned `\n` into a literal backslash-n, and `C:\Users` into `C:\\Users`.
    let windows = try decodeWindows("[" + window(id: 1, title: #"line1\nline2"#) + "]")

    XCTAssertEqual(windows.first?.title, "line1\nline2")
  }

  func testAWindowIdContainingFiveZerosIsNotRenumbered() throws {
    // `"00000" -> "0"` applied everywhere, so id 100000 arrived as 10 - and clicking that window
    // focused whatever else happened to own id 10, or nothing at all.
    let windows = try decodeWindows("[" + window(id: 100_000, title: "Safari") + "]")

    XCTAssertEqual(windows.first?.id, 100_000)
  }

  func testAWindowTitleContainingFiveZerosIsNotRewritten() throws {
    let windows = try decodeWindows("[" + window(id: 1, title: "Budget 100000 EUR") + "]")

    XCTAssertEqual(windows.first?.title, "Budget 100000 EUR")
  }

  func testAWindowTitleThatLooksLikeAMalformedArrayIsNotRepaired() throws {
    // The comma repairs ran over the whole document, strings included.
    let windows = try decodeWindows("[" + window(id: 1, title: "[,] and a,,b") + "]")

    XCTAssertEqual(windows.first?.title, "[,] and a,,b")
  }

  func testAFrameOfZerosKeepsItsPrecision() throws {
    // `0.0000` holds four zeros and `0.00000` five; neither is a malformed number.
    let json = """
      [{"id":1,"pid":42,"app":"Finder","title":"t","frame":{"x":0.00000,"y":0.00000,\
      "w":100.00000,"h":100.00000},"display":1,"space":1}]
      """
    let windows = try decodeWindows(json)

    XCTAssertEqual(windows.first?.frame.x, 0)
    XCTAssertEqual(windows.first?.frame.w, 100)
  }

  // MARK: - The malformed output it exists for

  func testAnEmptyArrayWrittenWithCommasBecomesAnEmptyArray() {
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[,]"), "[]")
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[,,,]"), "[]")
  }

  func testRepeatedAndTrailingCommasAreCollapsed() {
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[1,,2]"), "[1,2]")
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[1,2,]"), "[1,2]")
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[,1,2]"), "[1,2]")
  }

  func testALineContinuedWithABackslashIsJoined() {
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[1,\\\n2]"), "[1,2]")
  }

  func testANumberOfNothingButZerosBecomesZero() {
    // JSON forbids a leading zero, so `00000` was never a number a decoder would take. This is
    // the quirk the blanket replacement was written for, now confined to a whole number token.
    XCTAssertEqual(YabaiJSONSanitizer.sanitize(#"{"space":00000}"#), #"{"space":0}"#)
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[00,000]"), "[0,0]")
  }

  func testAZeroRunInsideALargerNumberIsLeftAlone() {
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[100000]"), "[100000]")
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[0.00000]"), "[0.00000]")
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[-0.000001]"), "[-0.000001]")
    XCTAssertEqual(YabaiJSONSanitizer.sanitize("[1e00000]"), "[1e00000]")
  }

  // MARK: - Malformed input it cannot make worse

  func testAnUnterminatedStringIsCopiedRatherThanRepaired() {
    // A truncated read is the one case where the string scanner cannot know where the value ends.
    // Copying the remainder verbatim is the safe way to be wrong.
    let truncated = #"[{"title":"unterminated,,"#

    XCTAssertEqual(YabaiJSONSanitizer.sanitize(truncated), truncated)
  }

  func testEmptyOutputStaysEmpty() {
    XCTAssertEqual(YabaiJSONSanitizer.sanitize(""), "")
  }

  // MARK: - A whole captured query

  /// One row as `yabai -m query --windows` actually prints it, reformatted onto fewer lines.
  /// Every field the app decodes is here, including the pretty-printer's four-zero decimals.
  private static let capturedWindow = """
    {"id":%ID%,"pid":6004,"app":"Code","title":"%TITLE%","scratchpad":"",    "frame":{"x":6.0000,"y":44.0000,"w":1698.0000,"h":1062.0000},"role":"AXWindow",    "subrole":"AXStandardWindow","root-window":true,"display":1,"space":2,"level":0,    "sub-level":0,"layer":"normal","sub-layer":"normal","opacity":1.0000,    "split-type":"none","split-child":"second_child","stack-index":2,"can-move":true,    "can-resize":true,"has-focus":true,"has-shadow":false,"is-native-fullscreen":false,    "is-visible":true,"is-minimized":false,"is-hidden":false,"is-floating":false,    "is-sticky":false,"is-grabbed":false}
    """

  private static func captured(id: Int, title: String) -> String {
    capturedWindow
      .replacingOccurrences(of: "%ID%", with: String(id))
      .replacingOccurrences(of: "%TITLE%", with: title)
  }

  func testRealCapturedOutputPassesThroughUntouched() throws {
    // The pretty-printer's `6.0000` and `1.0000` must survive, and so must the em dash: a real
    // query is the input this runs on thousands of times a day.
    let json = "[" + Self.captured(id: 2178, title: "README.md (Working Tree) \u{2014} MultiCAD")
      + "]"

    XCTAssertEqual(YabaiJSONSanitizer.sanitize(json), json, "a real query must be a no-op")
    let windows = try decodeWindows(json)
    XCTAssertEqual(windows.first?.id, 2178)
    XCTAssertEqual(windows.first?.frame.x, 6)
    XCTAssertEqual(windows.first?.stackIndex, 2)
  }

  func testACapturedQueryWithAndWithoutTheQuirkDecodesToTheSameWindows() throws {
    // The quirk this was written for, injected into a real row: a number token of nothing but
    // zeros, which no decoder would have taken.
    let clean = "[" + Self.captured(id: 100_000, title: #"Inbox (2) - \"work\""#) + ","
      + Self.captured(id: 7, title: "Terminal") + "]"
    let quirked = clean.replacingOccurrences(of: #""level":0,"#, with: #""level":00000,"#)

    let fromClean = try decodeWindows(clean)
    let fromQuirked = try decodeWindows(quirked)

    XCTAssertEqual(fromClean.map { $0.id }, [100_000, 7], "id 100000 is not renumbered to 10")
    XCTAssertEqual(fromClean.first?.title, #"Inbox (2) - "work""#)
    XCTAssertEqual(fromQuirked.map { $0.title }, fromClean.map { $0.title })
    XCTAssertEqual(fromQuirked.map { $0.id }, fromClean.map { $0.id })
  }
}
