import Foundation

/// Whether a profile name can be accepted.
///
/// The same question was asked in several sheets with slightly different rules - one trimmed
/// before comparing and one did not, so padding a name with spaces got a duplicate past the
/// check that existed to prevent it. `set profile "..."` matches by name, so duplicates make the
/// AppleScript API ambiguous.
enum ProfileNameValidator {

  /// A name with nothing but whitespace in it is not a name.
  static func isPresent(_ name: String) -> Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Whether no *other* profile already uses this name, ignoring case and surrounding space.
  ///
  /// `excluding` is the profile being renamed, so keeping its own name is not a collision.
  static func isUnique(
    _ name: String, among profiles: [LayoutProfile], excluding id: UUID? = nil
  ) -> Bool {
    let candidate = normalized(name)
    return !profiles.contains { profile in
      profile.id != id && normalized(profile.name) == candidate
    }
  }

  /// Both conditions, which is what every caller actually wants.
  static func isAcceptable(
    _ name: String, among profiles: [LayoutProfile], excluding id: UUID? = nil
  ) -> Bool {
    isPresent(name) && isUnique(name, among: profiles, excluding: id)
  }

  private static func normalized(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespaces).lowercased()
  }
}
