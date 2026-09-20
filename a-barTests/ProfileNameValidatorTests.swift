import XCTest

/// `set profile "..."` matches by name, so two profiles sharing one make the AppleScript API
/// ambiguous. The check that prevents it used to be written out per sheet, with different rules.
final class ProfileNameValidatorTests: XCTestCase {

  private func profile(_ name: String, id: UUID = UUID()) -> LayoutProfile {
    LayoutProfile(id: id, name: name, multiDisplayLayout: .defaultLayout, isDefault: false)
  }

  // MARK: - A name has to be a name

  func testABlankNameIsRefused() {
    XCTAssertFalse(ProfileNameValidator.isPresent(""))
    XCTAssertFalse(ProfileNameValidator.isPresent("   "))
    XCTAssertFalse(ProfileNameValidator.isPresent("\t"))
  }

  func testAnyRealTextIsAName() {
    XCTAssertTrue(ProfileNameValidator.isPresent("Work"))
    XCTAssertTrue(ProfileNameValidator.isPresent("  Work  "))
  }

  // MARK: - Uniqueness ignores case and surrounding space

  func testAnUnusedNameIsUnique() {
    XCTAssertTrue(ProfileNameValidator.isUnique("Home", among: [profile("Work")]))
  }

  func testAnExactDuplicateIsRefused() {
    XCTAssertFalse(ProfileNameValidator.isUnique("Work", among: [profile("Work")]))
  }

  func testCaseAloneDoesNotMakeANameUnique() {
    XCTAssertFalse(ProfileNameValidator.isUnique("WORK", among: [profile("work")]))
  }

  func testPaddingANameWithSpacesDoesNotMakeItUnique() {
    // regression: the new-profile sheet compared the untrimmed text while trimming it for the
    // "is it blank" check, so typing " Work " got a duplicate past a check meant to stop it.
    XCTAssertFalse(ProfileNameValidator.isUnique("  Work  ", among: [profile("Work")]))
    XCTAssertFalse(ProfileNameValidator.isUnique("Work", among: [profile("  Work  ")]))
  }

  // MARK: - Renaming

  func testAProfileKeepingItsOwnNameIsNotACollision() {
    let existing = profile("Work")

    XCTAssertTrue(
      ProfileNameValidator.isUnique("Work", among: [existing], excluding: existing.id),
      "renaming a profile to what it is already called is allowed")
  }

  func testRenamingOntoAnotherProfilesNameIsStillRefused() {
    let work = profile("Work")
    let home = profile("Home")

    XCTAssertFalse(
      ProfileNameValidator.isUnique("Home", among: [work, home], excluding: work.id))
  }

  func testChangingOnlyTheCaseOfAProfilesOwnNameIsAllowed() {
    let existing = profile("work")

    XCTAssertTrue(
      ProfileNameValidator.isUnique("Work", among: [existing], excluding: existing.id))
  }

  // MARK: - Both conditions together

  func testAcceptanceNeedsBothPresenceAndUniqueness() {
    let existing = [profile("Work")]

    XCTAssertTrue(ProfileNameValidator.isAcceptable("Home", among: existing))
    XCTAssertFalse(ProfileNameValidator.isAcceptable("", among: existing), "blank")
    XCTAssertFalse(ProfileNameValidator.isAcceptable("Work", among: existing), "duplicate")
    XCTAssertFalse(ProfileNameValidator.isAcceptable("   ", among: []), "blank with no rivals")
  }
}
