import XCTest

/// A place name the user typed has to survive the trip to a geocoder that only matches spellings
/// it already knows, and whatever comes back has to pick an icon that describes the sky.
final class WeatherPresentationTests: XCTestCase {

  // MARK: - Looking a place up

  func testThePlaceAsTypedIsTriedFirst() {
    // An exact match must never be passed over in favour of a looser spelling.
    XCTAssertEqual(WeatherPresentation.locationVariants("Lyon").first, "Lyon")
    XCTAssertEqual(WeatherPresentation.locationVariants("  Lyon  ").first, "Lyon")
  }

  func testACommaSeparatedPlaceIsAlsoTriedInShorterForms() {
    let variants = WeatherPresentation.locationVariants("Lyon, Rhone, France")

    XCTAssertEqual(variants.first, "Lyon, Rhone, France")
    XCTAssertTrue(variants.contains("Lyon"), "the city alone")
    XCTAssertTrue(variants.contains("Lyon, Rhone"), "and the first two parts")
  }

  func testAPostalCodeIsStripped() {
    // Geocoders generally do not match a free-text string containing a postal code.
    let variants = WeatherPresentation.locationVariants("Saint-Etienne 42000")

    XCTAssertTrue(
      variants.contains { !$0.contains("42000") && $0.contains("Saint") },
      "expected a digit-free variant, got \(variants)")
  }

  func testHyphensBecomeSpacesInTheStrippedForm() {
    let variants = WeatherPresentation.locationVariants("Saint-Etienne 42000")

    XCTAssertTrue(variants.contains("Saint Etienne"), "got \(variants)")
  }

  func testAccentsAreFoldedAway() {
    let variants = WeatherPresentation.locationVariants("Saint-Étienne")

    XCTAssertEqual(variants.first, "Saint-Étienne", "the faithful spelling is still first")
    XCTAssertTrue(variants.contains("Saint-Etienne"), "got \(variants)")
  }

  func testAPlaceWithNoAccentsGainsNoFoldedDuplicate() {
    XCTAssertEqual(WeatherPresentation.locationVariants("Lyon"), ["Lyon"])
  }

  func testNoVariantIsOfferedTwice() {
    // Every rule can produce the original spelling back; a duplicate is a wasted request.
    for place in ["Lyon", "Lyon, France", "Saint-Étienne 42000", "  Paris  "] {
      let variants = WeatherPresentation.locationVariants(place)

      XCTAssertEqual(Set(variants).count, variants.count, "duplicates for \(place): \(variants)")
    }
  }

  func testNoVariantIsEmpty() {
    let variants = WeatherPresentation.locationVariants("42000")

    XCTAssertFalse(variants.contains(""), "an empty query would match anything")
  }

  func testAnEmptyLocationProducesNothingToLookUp() {
    XCTAssertEqual(WeatherPresentation.locationVariants(""), [])
    XCTAssertEqual(WeatherPresentation.locationVariants("   "), [])
  }

  // MARK: - Weather codes

  func testKnownWeatherCodesAreDescribed() {
    XCTAssertEqual(WeatherPresentation.openMeteoDescription(for: 0), "Clear sky")
    XCTAssertEqual(WeatherPresentation.openMeteoDescription(for: 3), "Mainly clear")
    XCTAssertEqual(WeatherPresentation.openMeteoDescription(for: 61), "Rain")
    XCTAssertEqual(WeatherPresentation.openMeteoDescription(for: 95), "Thunderstorm")
  }

  func testAnUnknownWeatherCodeIsNamedRatherThanBlank() {
    XCTAssertEqual(WeatherPresentation.openMeteoDescription(for: 7), "Unknown")
    XCTAssertEqual(WeatherPresentation.openMeteoDescription(for: -1), "Unknown")
  }

  func testEveryDescribedCodeChoosesARealIcon() {
    // The two tables have to agree, or a forecast lands on the fallback icon.
    let described = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77,
                     80, 81, 82, 85, 86, 95, 96, 99]

    for code in described {
      let description = WeatherPresentation.openMeteoDescription(for: code)
      let icon = WeatherPresentation.icon(for: description, atNight: false)

      XCTAssertFalse(icon.symbol.isEmpty, "code \(code) -> \(description)")
    }
  }

  // MARK: - Temperature

  func testFreezingAndBoilingConvertBothWays() {
    XCTAssertEqual(WeatherPresentation.celsius(fromFahrenheit: 32), 0)
    XCTAssertEqual(WeatherPresentation.celsius(fromFahrenheit: 212), 100)
    XCTAssertEqual(WeatherPresentation.fahrenheit(fromCelsius: 0), 32)
    XCTAssertEqual(WeatherPresentation.fahrenheit(fromCelsius: 100), 212)
  }

  func testTheScalesMeetAtMinusForty() {
    XCTAssertEqual(WeatherPresentation.celsius(fromFahrenheit: -40), -40)
    XCTAssertEqual(WeatherPresentation.fahrenheit(fromCelsius: -40), -40)
  }

  func testConversionRoundsRatherThanTruncating() {
    // 21.5C is 70.7F, which should read 71 rather than 70.
    XCTAssertEqual(WeatherPresentation.fahrenheit(fromCelsius: 21.5), 71)
    XCTAssertEqual(WeatherPresentation.celsius(fromFahrenheit: 70), 21)
  }

  // MARK: - Icons

  func testAClearSkyIsSunByDayAndMoonByNight() {
    XCTAssertEqual(WeatherPresentation.icon(for: "Clear sky", atNight: false).symbol, "sun.max.fill")
    XCTAssertEqual(WeatherPresentation.icon(for: "Clear sky", atNight: true).symbol, "moon.fill")
  }

  func testAPartlySunnySkyGetsTheCloudAndSunIcon() {
    // regression: the plain sun branch was tested first and matched anything containing "sun",
    // so the cloud-and-sun symbol was unreachable for every possible description.
    XCTAssertEqual(
      WeatherPresentation.icon(for: "Partly sunny with cloud", atNight: false).symbol,
      "cloud.sun.fill")
    XCTAssertEqual(
      WeatherPresentation.icon(for: "Partly sunny with cloud", atNight: true).symbol,
      "cloud.moon.fill")
  }

  func testPlainCloudDoesNotBorrowTheSunIcon() {
    XCTAssertEqual(WeatherPresentation.icon(for: "Cloudy", atNight: false).symbol, "cloud.fill")
  }

  func testWetAndStormySkies() {
    XCTAssertEqual(WeatherPresentation.icon(for: "Rain", atNight: false).symbol, "cloud.rain.fill")
    XCTAssertEqual(
      WeatherPresentation.icon(for: "Drizzle", atNight: false).symbol, "cloud.rain.fill")
    XCTAssertEqual(
      WeatherPresentation.icon(for: "Thunderstorm", atNight: false).symbol, "cloud.bolt.fill")
    XCTAssertEqual(WeatherPresentation.icon(for: "Snow", atNight: false).symbol, "cloud.snow.fill")
    XCTAssertEqual(WeatherPresentation.icon(for: "Fog", atNight: false).symbol, "cloud.fog.fill")
  }

  func testAnUnrecognisedSkyStillGetsAnIcon() {
    XCTAssertEqual(WeatherPresentation.icon(for: "Unknown", atNight: false).symbol, "cloud.fill")
    XCTAssertEqual(WeatherPresentation.icon(for: "Unknown", atNight: true).symbol, "moon.fill")
    XCTAssertEqual(WeatherPresentation.icon(for: "", atNight: false).symbol, "cloud.fill")
  }

  func testDescriptionsAreMatchedRegardlessOfCaseAndSpacing() {
    XCTAssertEqual(WeatherPresentation.icon(for: "  RAIN  ", atNight: false).symbol, "cloud.rain.fill")
  }

  func testIconsCarryAColourRole() {
    XCTAssertEqual(WeatherPresentation.icon(for: "Clear sky", atNight: false).role, .yellow)
    XCTAssertEqual(WeatherPresentation.icon(for: "Rain", atNight: false).role, .blue)
    XCTAssertEqual(WeatherPresentation.icon(for: "Snow", atNight: false).role, .cyan)
    XCTAssertEqual(WeatherPresentation.icon(for: "Cloudy", atNight: false).role, .foreground)
  }
}
