import CoreGraphics
import Foundation

// Parsing only. The AppKit menu this feeds lives in XBarMenu.swift, which keeps this file
// free of UI dependencies so it can be compiled into the test target.


/// Parameters that can be attached to an xbar line item via pipe syntax
struct XBarParams: Equatable {
  var href: String?
  var color: String?
  var font: String?
  var size: CGFloat?
  var shell: String?
  var shellParams: [String]
  var terminal: Bool
  var refresh: Bool
  var dropdown: Bool
  var length: Int?
  var trim: Bool
  var alternate: Bool
  var image: String?
  var templateImage: String?
  var disabled: Bool
  var key: String?
  var ansi: Bool
  var emojize: Bool

  static let defaults = XBarParams(
    href: nil, color: nil, font: nil, size: nil,
    shell: nil, shellParams: [], terminal: true,
    refresh: false, dropdown: true, length: nil,
    trim: true, alternate: false, image: nil,
    templateImage: nil, disabled: false, key: nil,
    ansi: true, emojize: true
  )
}

/// A single parsed line from xbar-compatible script output
struct XBarLineItem: Equatable {
  var title: String
  var level: Int
  var isSeparator: Bool
  var params: XBarParams
}

/// Result of parsing xbar-compatible script output
struct XBarParsedOutput: Equatable {
  var headerLines: [XBarLineItem]
  var menuItems: [XBarLineItem]

  static let empty = XBarParsedOutput(headerLines: [], menuItems: [])
}

enum XBarParser {

  /// Parse raw script output into structured xbar items
  static func parse(_ output: String) -> XBarParsedOutput {
    // Split on any newline, not just "\n". A script that echoes CRLF - anything curling an API,
    // or written on another machine - otherwise left a trailing "\r" on every line, which meant
    // "---\r" never matched the separator and the whole dropdown silently stayed in the bar.
    // `CharacterSet.whitespaces` is space and tab only, so trimming the line did not save it.
    let lines = output.components(separatedBy: .newlines)

    var headerLines: [XBarLineItem] = []
    var menuItems: [XBarLineItem] = []
    var inMenu = false

    for line in lines {
      if line.isEmpty { continue }

      let stripped = line.trimmingCharacters(in: .whitespaces)
      if stripped == "---" {
        if !inMenu {
          inMenu = true
        } else {
          menuItems.append(
            XBarLineItem(title: "", level: 0, isSeparator: true, params: .defaults))
        }
        continue
      }

      let item = parseLine(line, isMenuSection: inMenu)

      if inMenu {
        menuItems.append(item)
      } else {
        headerLines.append(item)
      }
    }

    return XBarParsedOutput(headerLines: headerLines, menuItems: menuItems)
  }

  /// Parse a single line with optional pipe-delimited parameters
  private static func parseLine(_ line: String, isMenuSection: Bool) -> XBarLineItem {
    var workingLine = line
    var level = 0

    // Determine submenu level from leading pairs of dashes (menu section only)
    if isMenuSection {
      while workingLine.hasPrefix("--") {
        level += 1
        workingLine = String(workingLine.dropFirst(2))
      }
    }

    // Split by pipe to separate title and params
    let parts = splitByPipe(workingLine)
    let rawTitle = parts.first ?? ""
    let paramParts = Array(parts.dropFirst())

    // Parse parameters
    var params = XBarParams.defaults

    for part in paramParts {
      let trimmed = part.trimmingCharacters(in: .whitespaces)
      guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }

      let key = String(trimmed[trimmed.startIndex..<equalsIndex])
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
      var value = String(trimmed[trimmed.index(after: equalsIndex)...])
        .trimmingCharacters(in: .whitespaces)

      // Remove surrounding quotes
      if (value.hasPrefix("\"") && value.hasSuffix("\""))
        || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value = String(value.dropFirst().dropLast())
      }

      switch key {
      case "href": params.href = value
      case "color": params.color = value
      case "font": params.font = value
      case "size": params.size = CGFloat(Double(value) ?? 0)
      case "shell": params.shell = value
      case "terminal": params.terminal = value.lowercased() == "true"
      case "refresh": params.refresh = value.lowercased() == "true"
      case "dropdown": params.dropdown = value.lowercased() != "false"
      case "length": params.length = Int(value)
      case "trim": params.trim = value.lowercased() != "false"
      case "alternate": params.alternate = value.lowercased() == "true"
      case "image": params.image = value
      case "templateimage": params.templateImage = value
      case "disabled": params.disabled = value.lowercased() == "true"
      case "key": params.key = value
      case "ansi": params.ansi = value.lowercased() != "false"
      case "emojize": params.emojize = value.lowercased() != "false"
      default:
        if key.hasPrefix("param"), let num = Int(key.dropFirst(5)), num > 0 {
          while params.shellParams.count < num {
            params.shellParams.append("")
          }
          params.shellParams[num - 1] = value
        }
      }
    }

    let finalTitle = params.trim ? rawTitle.trimmingCharacters(in: .whitespaces) : rawTitle

    return XBarLineItem(
      title: finalTitle,
      level: level,
      isSeparator: false,
      params: params
    )
  }

  /// Split a string by pipe character, respecting quoted strings
  private static func splitByPipe(_ string: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inQuote: Character? = nil

    for char in string {
      if let q = inQuote {
        current.append(char)
        if char == q { inQuote = nil }
      } else if char == "\"" || char == "'" {
        current.append(char)
        inQuote = char
      } else if char == "|" {
        parts.append(current)
        current = ""
      } else {
        current.append(char)
      }
    }
    parts.append(current)

    return parts
  }
}
