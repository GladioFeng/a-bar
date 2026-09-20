import XCTest

/// A custom widget's output is untrusted text from a script the user wrote. Every line must
/// parse to something displayable, and a parameter the parser does not understand must cost
/// that parameter only - never the line, and never the menu.
final class XBarParserTests: XCTestCase {

  private func header(_ output: String) -> [XBarLineItem] {
    XBarParser.parse(output).headerLines
  }

  private func menu(_ output: String) -> [XBarLineItem] {
    XBarParser.parse(output).menuItems
  }

  private func params(_ line: String) -> XBarParams {
    XBarParser.parse(line).headerLines.first?.params ?? .defaults
  }

  // MARK: - Splitting the bar from the dropdown

  func testOutputWithoutASeparatorIsAllHeader() {
    let parsed = XBarParser.parse("first\nsecond")

    XCTAssertEqual(parsed.headerLines.map { $0.title }, ["first", "second"])
    XCTAssertEqual(parsed.menuItems, [], "no dropdown was asked for")
  }

  func testTheFirstSeparatorOpensTheDropdown() {
    let parsed = XBarParser.parse("bar text\n---\nmenu entry")

    XCTAssertEqual(parsed.headerLines.map { $0.title }, ["bar text"])
    XCTAssertEqual(parsed.menuItems.map { $0.title }, ["menu entry"])
  }

  func testLaterSeparatorsBecomeDividersInsideTheDropdown() {
    // Only the first `---` switches section; the rest are horizontal rules.
    let items = menu("head\n---\none\n---\ntwo")

    XCTAssertEqual(items.count, 3)
    XCTAssertFalse(items[0].isSeparator)
    XCTAssertTrue(items[1].isSeparator, "the second --- draws a divider")
    XCTAssertEqual(items[1].title, "", "a divider carries no text")
    XCTAssertEqual(items[2].title, "two")
  }

  func testASeparatorIsRecognisedDespiteSurroundingSpace() {
    XCTAssertEqual(menu("head\n  ---  \nentry").map { $0.title }, ["entry"])
  }

  func testBlankLinesAreDropped() {
    XCTAssertEqual(header("one\n\n\ntwo").map { $0.title }, ["one", "two"])
  }

  func testEmptyOutputParsesToNothing() {
    XCTAssertEqual(XBarParser.parse(""), .empty)
    XCTAssertEqual(XBarParser.parse("\n\n"), .empty)
  }

  // MARK: - Submenu nesting

  func testLeadingDashPairsSetTheSubmenuLevel() {
    let items = menu("head\n---\ntop\n--nested\n----deeper")

    XCTAssertEqual(items.map { $0.level }, [0, 1, 2])
    XCTAssertEqual(items.map { $0.title }, ["top", "nested", "deeper"])
  }

  func testDashesInTheBarSectionAreJustText() {
    // Nesting only means something inside the dropdown; a header line keeps its dashes.
    XCTAssertEqual(header("--not nested").map { $0.title }, ["--not nested"])
    XCTAssertEqual(header("--not nested").map { $0.level }, [0])
  }

  func testAnOddDashIsLeftOnTheTitle() {
    let items = menu("head\n---\n---odd")

    XCTAssertEqual(items.first?.level, 1, "the pair counts")
    XCTAssertEqual(items.first?.title, "-odd", "the leftover dash stays in the text")
  }

  // MARK: - Parameters after the pipe

  func testALineWithoutParametersKeepsTheDefaults() {
    XCTAssertEqual(params("plain"), XBarParams.defaults)
  }

  func testTitleAndParametersAreSplitOnThePipe() {
    let parsed = XBarParser.parse("Build OK | color=green")

    XCTAssertEqual(parsed.headerLines.first?.title, "Build OK")
    XCTAssertEqual(parsed.headerLines.first?.params.color, "green")
  }

  func testParameterKeysAreCaseInsensitive() {
    XCTAssertEqual(params("t | COLOR=red").color, "red")
    XCTAssertEqual(params("t | TemplateImage=abc").templateImage, "abc")
  }

  func testQuotedValuesLoseTheirQuotes() {
    XCTAssertEqual(params(#"t | href="http://example.com""#).href, "http://example.com")
    XCTAssertEqual(params("t | font='SF Mono'").font, "SF Mono")
  }

  func testAPipeInsideQuotesDoesNotSplitTheLine() {
    // A shell command with a pipe in it is the reason the splitter is quote-aware.
    let parsed = XBarParser.parse(#"t | shell="ps aux | grep x" | terminal=true"#)

    XCTAssertEqual(parsed.headerLines.first?.params.shell, "ps aux | grep x")
    XCTAssertTrue(parsed.headerLines.first?.params.terminal ?? false, "the next param still parses")
  }

  func testAParameterWithoutAnEqualsIsIgnoredWithoutLosingTheOthers() {
    let result = params("t | garbage | color=red")

    XCTAssertEqual(result.color, "red", "the sibling parameter survives")
  }

  func testAnUnknownParameterIsIgnoredWithoutLosingTheOthers() {
    let result = params("t | nosuchkey=1 | color=red")

    XCTAssertEqual(result.color, "red")
    XCTAssertEqual(result, { var p = XBarParams.defaults; p.color = "red"; return p }())
  }

  func testNumericValuesThatDoNotParseFallBack() {
    XCTAssertEqual(params("t | size=abc").size, 0, "an unreadable size is zero, not a crash")
    XCTAssertNil(params("t | length=abc").length, "an unreadable length is simply absent")
    XCTAssertEqual(params("t | size=14").size, 14)
    XCTAssertEqual(params("t | length=20").length, 20)
  }

  // MARK: - Boolean parameters do not all default the same way

  func testFlagsThatAreOnUnlessTurnedOff() {
    // dropdown, trim, ansi and emojize test `!= "false"`, so anything unrecognised leaves them on.
    XCTAssertTrue(XBarParams.defaults.dropdown)
    XCTAssertFalse(params("t | dropdown=false").dropdown)
    XCTAssertTrue(params("t | dropdown=true").dropdown)
    XCTAssertTrue(params("t | dropdown=yes").dropdown, "only the word false turns it off")

    XCTAssertFalse(params("t | ansi=false").ansi)
    XCTAssertFalse(params("t | emojize=false").emojize)
  }

  func testFlagsThatAreOffUnlessTurnedOn() {
    // terminal, refresh and alternate test `== "true"`, so anything unrecognised leaves them off.
    XCTAssertFalse(XBarParams.defaults.refresh)
    XCTAssertTrue(params("t | refresh=true").refresh)
    XCTAssertFalse(params("t | refresh=yes").refresh, "only the word true turns it on")

    XCTAssertTrue(params("t | alternate=true").alternate)
    XCTAssertTrue(params("t | disabled=true").disabled)
  }

  func testTerminalIsOnByDefaultButOffWhenSetToAnythingButTrue() {
    // The odd one out: it defaults to true, yet is parsed with `== "true"`, so `terminal=yes`
    // turns it off where `dropdown=yes` would leave dropdown on.
    XCTAssertTrue(XBarParams.defaults.terminal)
    XCTAssertFalse(params("t | terminal=false").terminal)
    XCTAssertFalse(params("t | terminal=yes").terminal)
    XCTAssertTrue(params("t | terminal=true").terminal)
  }

  func testBooleanValuesAreCaseInsensitive() {
    XCTAssertFalse(params("t | dropdown=FALSE").dropdown)
    XCTAssertTrue(params("t | refresh=TRUE").refresh)
  }

  // MARK: - Shell arguments are a sparse, one-based list

  func testShellParametersFillByTheirOwnIndex() {
    let result = params("t | shell=/bin/echo | param1=one | param2=two")

    XCTAssertEqual(result.shellParams, ["one", "two"])
  }

  func testAGapInTheNumberingIsPaddedRatherThanMisordered() {
    // param3 without param2 must not shift the argument left into param2's position.
    let result = params("t | param1=one | param3=three")

    XCTAssertEqual(result.shellParams, ["one", "", "three"])
  }

  func testParametersGivenOutOfOrderLandInTheirNumberedSlots() {
    let result = params("t | param3=three | param1=one")

    XCTAssertEqual(result.shellParams, ["one", "", "three"])
  }

  func testParamZeroIsIgnoredBecauseTheListIsOneBased() {
    XCTAssertEqual(params("t | param0=nope").shellParams, [])
  }

  func testAParamWithoutANumberIsIgnored() {
    XCTAssertEqual(params("t | param=nope").shellParams, [])
    XCTAssertEqual(params("t | paramX=nope").shellParams, [])
  }

  func testARepeatedParamNumberTakesTheLastValue() {
    XCTAssertEqual(params("t | param1=first | param1=second").shellParams, ["second"])
  }

  // MARK: - Trimming

  func testTitlesAreTrimmedByDefault() {
    XCTAssertEqual(header("   padded   ").first?.title, "padded")
  }

  func testTrimmingCanBeTurnedOffToKeepDeliberateSpacing() {
    // Scripts use leading spaces to align columns in the dropdown.
    XCTAssertEqual(header("   padded    | trim=false").first?.title, "   padded    ")
  }

  // MARK: - A realistic script

  func testATypicalScriptParsesEndToEnd() {
    let output = """
      CPU 42% | color=#ff8800 | size=12
      ---
      Top process | disabled=true
      --Restart it | shell=/usr/bin/killall | param1=Dock | terminal=false
      ---
      Refresh | refresh=true
      """

    let parsed = XBarParser.parse(output)

    XCTAssertEqual(parsed.headerLines.map { $0.title }, ["CPU 42%"])
    XCTAssertEqual(parsed.headerLines.first?.params.color, "#ff8800")
    XCTAssertEqual(parsed.headerLines.first?.params.size, 12)

    XCTAssertEqual(parsed.menuItems.count, 4)
    XCTAssertTrue(parsed.menuItems[0].params.disabled)
    XCTAssertEqual(parsed.menuItems[1].level, 1)
    XCTAssertEqual(parsed.menuItems[1].params.shellParams, ["Dock"])
    XCTAssertFalse(parsed.menuItems[1].params.terminal)
    XCTAssertTrue(parsed.menuItems[2].isSeparator)
    XCTAssertTrue(parsed.menuItems[3].params.refresh)
  }

  func testWindowsLineEndingsDoNotLeaveStrayCarriageReturns() {
    // regression: lines were split on "\n" alone, so CRLF output left a "\r" on every line.
    // "---\r" then failed to match the separator - trimming did not help, because
    // `CharacterSet.whitespaces` covers space and tab but not carriage return - and the entire
    // dropdown stayed in the bar with stray control characters in every title.
    let parsed = XBarParser.parse("one\r\n---\r\ntwo")

    XCTAssertEqual(parsed.headerLines.map { $0.title }, ["one"])
    XCTAssertEqual(parsed.menuItems.map { $0.title }, ["two"])
  }

  func testALoneCarriageReturnAlsoSeparatesLines() {
    let parsed = XBarParser.parse("one\r---\rtwo")

    XCTAssertEqual(parsed.headerLines.map { $0.title }, ["one"])
    XCTAssertEqual(parsed.menuItems.map { $0.title }, ["two"])
  }

  func testUnixOutputIsUnaffected() {
    let parsed = XBarParser.parse("one\n---\ntwo\nthree")

    XCTAssertEqual(parsed.headerLines.map { $0.title }, ["one"])
    XCTAssertEqual(parsed.menuItems.map { $0.title }, ["two", "three"])
  }
}
