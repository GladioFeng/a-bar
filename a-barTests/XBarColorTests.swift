import AppKit
import XCTest

/// Colors in xbar output are written by whoever wrote the script, in whichever of the four
/// accepted spellings they reached for. Anything unparseable has to come back nil so the menu
/// falls back to the default label color rather than rendering an item invisible.
final class XBarColorTests: XCTestCase {

    private func rgba(_ string: String, line: UInt = #line) -> (
        r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    )? {
        guard let color = NSColor(xbarString: string)?.usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }

    private func assertComponents(
        _ string: String,
        _ expected: (CGFloat, CGFloat, CGFloat, CGFloat),
        accuracy: CGFloat = 0.01,
        line: UInt = #line
    ) {
        guard let got = rgba(string) else {
            return XCTFail("\(string) did not parse", line: line)
        }
        XCTAssertEqual(got.r, expected.0, accuracy: accuracy, "red of \(string)", line: line)
        XCTAssertEqual(got.g, expected.1, accuracy: accuracy, "green of \(string)", line: line)
        XCTAssertEqual(got.b, expected.2, accuracy: accuracy, "blue of \(string)", line: line)
        XCTAssertEqual(got.a, expected.3, accuracy: accuracy, "alpha of \(string)", line: line)
    }

    // MARK: - Named colors

    func testEveryNamedColorIsRecognized() {
        let names = [
            "red", "blue", "green", "yellow", "orange", "purple", "pink", "white", "black",
            "gray", "grey", "cyan", "magenta", "brown", "teal", "indigo", "mint", "cadetblue",
        ]
        for name in names {
            XCTAssertNotNil(NSColor(xbarString: name), "'\(name)' should be a known color")
        }
    }

    func testNamedColorsAreMatchedRegardlessOfCaseOrSurroundingSpace() {
        XCTAssertNotNil(NSColor(xbarString: "  RED\n"))
    }

    func testGrayAndGreySpellingsAgree() {
        XCTAssertEqual(NSColor(xbarString: "gray"), NSColor(xbarString: "grey"))
    }

    func testAnUnknownNameIsRejected() {
        XCTAssertNil(NSColor(xbarString: "burnt-sienna"))
    }

    // MARK: - Hex

    func testThreeDigitHexExpandsEachNibble() {
        assertComponents("#f00", (1, 0, 0, 1))
        assertComponents("#fff", (1, 1, 1, 1))
    }

    func testSixDigitHexIsOpaque() {
        assertComponents("#00ff80", (0, 1, 0.502, 1))
    }

    func testEightDigitHexCarriesAlphaLast() {
        assertComponents("#ff000080", (1, 0, 0, 0.502))
    }

    func testHexIsCaseInsensitive() {
        XCTAssertEqual(NSColor(xbarString: "#ABCDEF"), NSColor(xbarString: "#abcdef"))
    }

    func testHexOfAnUnsupportedLengthIsRejected() {
        for bad in ["#ff", "#ffff", "#fffff", "#fffffff"] {
            XCTAssertNil(NSColor(xbarString: bad), "'\(bad)' is not a hex length xbar accepts")
        }
    }

    func testNonHexDigitsAreRejected() {
        XCTAssertNil(NSColor(xbarString: "#zzzzzz"))
    }

    // MARK: - rgb() and rgba()

    func testRGBParsesThreeChannelsAsOpaque() {
        assertComponents("rgb(255, 0, 128)", (1, 0, 0.502, 1))
    }

    func testRGBAParsesAFractionalAlpha() {
        assertComponents("rgba(0, 255, 0, 0.5)", (0, 1, 0, 0.5))
    }

    func testWhitespaceInsideTheParenthesesIsTolerated() {
        assertComponents("rgb(  10 ,20,  30 )", (10 / 255, 20 / 255, 30 / 255, 1))
    }

    func testRGBAWithoutItsAlphaIsTreatedAsOpaque() {
        assertComponents("rgba(1,2,3)", (1 / 255, 2 / 255, 3 / 255, 1))
    }

    func testAMalformedRGBIsRejected() {
        for bad in ["rgb()", "rgb(1,2)", "rgb(a,b,c)", "rgb 1,2,3"] {
            XCTAssertNil(NSColor(xbarString: bad), "'\(bad)' should not parse")
        }
    }

    // MARK: - Nothing at all

    func testEmptyAndUnrelatedStringsAreRejected() {
        XCTAssertNil(NSColor(xbarString: ""))
        XCTAssertNil(NSColor(xbarString: "   "))
        XCTAssertNil(NSColor(xbarString: "hsl(0,0%,0%)"))
    }
}
