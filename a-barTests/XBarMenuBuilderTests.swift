import AppKit
import XCTest

/// The dropdown a custom widget shows is built from parsed xbar output, and the shape of that
/// menu is decided entirely by `XBarMenuBuilder`. Nesting is driven by an indentation level
/// rather than by structure, so the parent an item lands under is computed, not given - which
/// is exactly the kind of thing that breaks quietly and leaves a submenu hanging off the wrong
/// row, or a separator swallowed into somebody's submenu.
final class XBarMenuBuilderTests: XCTestCase {
    private var handler: XBarMenuActionHandler!

    override func setUp() {
        super.setUp()
        handler = XBarMenuActionHandler()
    }

    override func tearDown() {
        handler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func item(
        _ title: String,
        level: Int = 0,
        separator: Bool = false,
        _ configure: (inout XBarParams) -> Void = { _ in }
    ) -> XBarLineItem {
        var params = XBarParams.defaults
        configure(&params)
        return XBarLineItem(title: title, level: level, isSeparator: separator, params: params)
    }

    private func menu(header: [XBarLineItem] = [], items: [XBarLineItem] = []) -> NSMenu {
        XBarMenuBuilder.buildMenu(
            from: XBarParsedOutput(headerLines: header, menuItems: items),
            handler: handler)
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    // MARK: - Which lines become menu items

    func testHeaderLinesAreNotRepeatedWhenTheScriptHasADropdown() {
        // The header is already on the bar. Only a line explicitly marked `dropdown=true`
        // belongs in both places, and `dropdown` defaults to true.
        let result = menu(
            header: [item("shown"), item("hidden") { $0.dropdown = false }],
            items: [item("body")])

        XCTAssertEqual(titles(result), ["shown", "---", "body"],
                       "the dropdown header is echoed, then separated from the body")
    }

    func testWithoutASeparatorTheDropdownIsBuiltFromHeaderLinesAlone() {
        // No `---` in the output means every line parsed as a header. A script that only
        // prints lines still gets a usable dropdown out of the ones marked dropdown=true.
        let result = menu(header: [item("one"), item("two") { $0.dropdown = false }])

        XCTAssertEqual(titles(result), ["one"])
    }

    func testAHeaderThatIsEntirelyNonDropdownAddsNoLeadingSeparator() {
        let result = menu(header: [item("hidden") { $0.dropdown = false }], items: [item("body")])

        XCTAssertEqual(titles(result), ["body"], "nothing to separate the body from")
    }

    func testEmptyOutputProducesAnEmptyMenu() {
        XCTAssertEqual(menu().items.count, 0)
    }

    // MARK: - Nesting by indentation level

    func testDeeperLevelsBecomeSubmenusOfThePrecedingItem() {
        let result = menu(items: [item("parent"), item("child", level: 1)])

        XCTAssertEqual(titles(result), ["parent"])
        XCTAssertEqual(result.items[0].submenu.map(titles), ["child"])
    }

    func testNestingUnwindsWhenTheLevelDropsBackDown() {
        let result = menu(items: [
            item("a"),
            item("a1", level: 1),
            item("a1x", level: 2),
            item("b"),
        ])

        XCTAssertEqual(titles(result), ["a", "b"], "b is a sibling of a, not its descendant")
        let a1 = result.items[0].submenu
        XCTAssertEqual(a1.map(titles), ["a1"])
        XCTAssertEqual(a1?.items[0].submenu.map(titles), ["a1x"])
    }

    func testSiblingsAtTheSameLevelShareAParent() {
        let result = menu(items: [item("parent"), item("x", level: 1), item("y", level: 1)])

        XCTAssertEqual(result.items[0].submenu.map(titles), ["x", "y"])
    }

    func testAnItemWithNoChildrenKeepsNoEmptySubmenu() {
        // Every item gets a submenu allocated up front in case children follow. One that stays
        // empty has to be torn back off, or the row grows a disclosure arrow that opens nothing.
        let result = menu(items: [item("lonely")])

        XCTAssertNil(result.items[0].submenu)
    }

    // MARK: - Separators

    func testASeparatorInsideNestedItemsReturnsToTheRootMenu() {
        // A separator is always a top-level divider. Without the unwind it would be added to
        // the open submenu of whichever item happened to come before it.
        let result = menu(items: [
            item("parent"),
            item("child", level: 1),
            item("", separator: true),
            item("after"),
        ])

        XCTAssertEqual(titles(result), ["parent", "---", "after"])
        XCTAssertEqual(result.items[0].submenu.map(titles), ["child"],
                       "the separator did not land in the submenu")
    }

    // MARK: - Item rendering

    func testTitleLongerThanLengthIsTruncatedAndKeepsTheFullTextAsATooltip() {
        let result = menu(items: [item("abcdefghij") { $0.length = 4 }])

        XCTAssertEqual(result.items[0].title, "abcd…")
        XCTAssertEqual(result.items[0].toolTip, "abcdefghij",
                       "the untruncated title stays reachable on hover")
    }

    func testTitleShorterThanLengthIsLeftAloneAndGetsNoTooltip() {
        let result = menu(items: [item("ab") { $0.length = 4 }])

        XCTAssertEqual(result.items[0].title, "ab")
        XCTAssertNil(result.items[0].toolTip)
    }

    func testDisabledItemsAreNotClickableEvenWhenTheyCarryAnAction() {
        let result = menu(items: [item("nope") { $0.disabled = true; $0.href = "https://x.test" }])

        XCTAssertFalse(result.items[0].isEnabled)
        XCTAssertNil(result.items[0].action, "a disabled row must not fire its href")
    }

    func testOnlyItemsWithSomethingToDoGetAnAction() {
        let inert = menu(items: [item("label")]).items[0]
        XCTAssertNil(inert.action)
        XCTAssertNil(inert.representedObject)

        for (name, configure) in [
            ("href", { (p: inout XBarParams) in p.href = "https://x.test" }),
            ("shell", { (p: inout XBarParams) in p.shell = "echo hi" }),
            ("refresh", { (p: inout XBarParams) in p.refresh = true }),
        ] {
            let built = menu(items: [item(name, configure)]).items[0]
            XCTAssertNotNil(built.action, "\(name) should be actionable")
            XCTAssertTrue(built.target === handler)
            XCTAssertTrue(built.representedObject is XBarLineItemWrapper,
                          "the handler needs the line item back to act on it")
        }
    }

    func testAlternateItemsAreMarkedForTheOptionKey() {
        let result = menu(items: [item("alt") { $0.alternate = true }])

        XCTAssertTrue(result.items[0].isAlternate)
        XCTAssertEqual(result.items[0].keyEquivalentModifierMask, .option)
    }

    func testColorAndSizeReachTheAttributedTitle() {
        let result = menu(items: [item("styled") { $0.color = "red"; $0.size = 18 }])
        let attrs = result.items[0].attributedTitle?.attributes(at: 0, effectiveRange: nil)

        XCTAssertNotNil(attrs?[.foregroundColor])
        XCTAssertEqual((attrs?[.font] as? NSFont)?.pointSize, 18)
    }

    func testAnUnparseableColorLeavesTheTitleUncolored() {
        let result = menu(items: [item("plain") { $0.color = "not-a-color" }])
        let attrs = result.items[0].attributedTitle?.attributes(at: 0, effectiveRange: nil)

        XCTAssertNil(attrs?[.foregroundColor])
    }

    func testAnUnknownFontFallsBackToTheMenuFontAtTheRequestedSize() {
        let result = menu(items: [item("x") { $0.font = "NoSuchFont"; $0.size = 20 }])
        let font = result.items[0].attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        XCTAssertEqual(font?.pointSize, 20)
    }

    func testAnImageIsDecodedFromBase64AndSizedForAMenu() {
        let png = NSImage(size: NSSize(width: 4, height: 4))
        png.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        png.unlockFocus()
        let data = NSBitmapImageRep(data: png.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!

        let result = menu(items: [item("img") { $0.image = data.base64EncodedString() }])

        XCTAssertEqual(result.items[0].image?.size, NSSize(width: 16, height: 16))
        XCTAssertFalse(result.items[0].image?.isTemplate ?? true)
    }

    func testATemplateImageIsMarkedAsOneSoItTakesTheMenuTint() {
        let png = NSImage(size: NSSize(width: 4, height: 4))
        png.lockFocus()
        NSColor.black.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        png.unlockFocus()
        let data = NSBitmapImageRep(data: png.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!

        let result = menu(items: [item("img") { $0.templateImage = data.base64EncodedString() }])

        XCTAssertTrue(result.items[0].image?.isTemplate ?? false)
    }

    func testGarbageImageDataLeavesTheItemWithoutAnImage() {
        let result = menu(items: [item("img") { $0.image = "not base64 at all !!" }])

        XCTAssertNil(result.items[0].image)
    }

    // MARK: - Key shortcuts

    func testKeyShortcutModifiersAndKeyAreParsed() {
        let result = menu(items: [item("save") { $0.key = "CmdOrCtrl+shift+s" }])

        XCTAssertEqual(result.items[0].keyEquivalent, "s")
        XCTAssertEqual(result.items[0].keyEquivalentModifierMask, [.command, .shift])
    }

    func testNamedKeysMapToTheirControlCharacters() {
        let cases: [(String, String)] = [
            ("return", "\r"), ("enter", "\r"), ("escape", "\u{1B}"), ("esc", "\u{1B}"),
            ("tab", "\t"), ("space", " "), ("plus", "+"),
        ]
        for (name, expected) in cases {
            let result = menu(items: [item("k") { $0.key = name }])
            XCTAssertEqual(result.items[0].keyEquivalent, expected, "key '\(name)'")
        }
    }

    func testEachModifierSpellingIsAccepted() {
        let cases: [(String, NSEvent.ModifierFlags)] = [
            ("cmd", .command), ("command", .command),
            ("option", .option), ("alt", .option), ("optionoralt", .option),
            ("ctrl", .control), ("control", .control), ("shift", .shift),
        ]
        for (name, expected) in cases {
            let result = menu(items: [item("k") { $0.key = "\(name)+a" }])
            XCTAssertEqual(result.items[0].keyEquivalentModifierMask, expected, "modifier '\(name)'")
        }
    }

    func testAMultiCharacterUnknownTokenIsNotTakenAsTheKey() {
        let result = menu(items: [item("k") { $0.key = "cmd+nonsense" }])

        XCTAssertEqual(result.items[0].keyEquivalent, "")
        XCTAssertEqual(result.items[0].keyEquivalentModifierMask, .command)
    }
}
