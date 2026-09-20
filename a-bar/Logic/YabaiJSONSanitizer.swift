import Foundation

/// Repairing the JSON yabai hands back.
///
/// Old yabai builds could emit output that no decoder would accept - a trailing comma in an
/// array, an empty array written `[,]`, a line continued with a backslash. This used to be a
/// private helper on `YabaiService` applied to every query, and it repaired those by running a
/// handful of blind string replacements over the whole document. Three of them did more harm
/// than the malformed output ever did:
///
/// - `\` was doubled and `\\"` then collapsed to `"`, so a window titled `He said "hi"` arrived
///   as `"title":"He said "hi""` and the *entire* query failed to decode. Every yabai widget went
///   blank for as long as any window had a quote in its title. That pair repaired nothing - it
///   only ever took valid JSON and made it invalid - so it is gone rather than narrowed.
/// - `00000` became `0` everywhere, so window id `100000` became `10` and a window titled
///   `Budget 100000 EUR` became `Budget 10 EUR`. A wrong id means clicking the window focuses
///   something else, or nothing.
/// - The comma repairs rewrote the contents of strings too, so a window titled `[,]` was retitled.
///
/// The repairs now run only *outside* string literals, which gives the property the old version
/// could not have: **a document that is already valid JSON comes back byte for byte unchanged.**
/// Everything it still rewrites is invalid JSON before it is touched, so no reading of a real
/// window can be altered by it.
enum YabaiJSONSanitizer {

  /// Repair the structure of `json` without altering any value inside it.
  static func sanitize(_ json: String) -> String {
    var result = ""
    result.reserveCapacity(json.count)
    var outside = ""

    func flushOutside() {
      result += repairStructure(outside)
      outside.removeAll(keepingCapacity: true)
    }

    var index = json.startIndex
    while index < json.endIndex {
      let character = json[index]
      guard character == "\"" else {
        outside.append(character)
        index = json.index(after: index)
        continue
      }

      // A string literal is copied through verbatim, escapes and all. An unterminated one - which
      // only a truncated read produces - takes the rest of the document with it, which is the
      // safe way to be wrong: nothing is rewritten.
      flushOutside()
      result.append(character)
      index = json.index(after: index)
      while index < json.endIndex {
        let inner = json[index]
        result.append(inner)
        index = json.index(after: index)
        if inner == "\\", index < json.endIndex {
          result.append(json[index])
          index = json.index(after: index)
        } else if inner == "\"" {
          break
        }
      }
    }

    flushOutside()
    return result
  }

  /// The repairs, applied to a run of text known to be outside any string literal.
  private static func repairStructure(_ fragment: String) -> String {
    guard !fragment.isEmpty else { return "" }
    var repaired = fragment

    // A line continued with a backslash. Outside a string a backslash is never valid JSON.
    repaired = repaired.replacingOccurrences(of: "\\\n", with: "")

    // `[,]`, `[1,,2]` and `[1,]`, in that order: collapse runs first so the bracket rules see a
    // single comma.
    repaired = repaired.replacingOccurrences(of: ",{2,}", with: ",", options: .regularExpression)
    repaired = repaired.replacingOccurrences(of: "\\[,", with: "[", options: .regularExpression)
    repaired = repaired.replacingOccurrences(of: ",\\]", with: "]", options: .regularExpression)

    // A number written as nothing but zeros. JSON forbids a leading zero, so `00000` was never a
    // valid number and `0` is what it meant. The lookaround keeps this to a whole token: the
    // `00000` inside `100000` and the one inside `0.000001` are both left alone.
    repaired = repaired.replacingOccurrences(
      of: "(?<![0-9A-Za-z_.+-])0{2,}(?![0-9A-Za-z_.])", with: "0", options: .regularExpression)

    return repaired
  }
}
