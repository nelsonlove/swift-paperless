//
//  FileNaming.swift
//  FileProviderCore
//

import DataModel
import Foundation

/// File and folder names for items in the Files app.
public enum FileNaming {
  /// The longest stem kept, in UTF-8 bytes. APFS allows 255 bytes per name;
  /// this leaves room for a collision suffix and an extension.
  public static let maxStemBytes = 200

  /// The longest extension kept, in characters.
  public static let maxExtensionLength = 16

  /// The extension used for archived documents and as the fallback.
  public static let pdfExtension = "pdf"

  /// Makes a string safe to use as one path component.
  ///
  /// Replaces `/` and `:` with `-`, replaces control characters and line or
  /// paragraph separators with a space, collapses runs of whitespace, applies
  /// Unicode NFC, trims whitespace and leading dots (a leading dot hides the
  /// file), and caps the length at ``maxStemBytes``. Returns `nil` when nothing
  /// is left.
  public static func sanitize(_ raw: String) -> String? {
    var scalars = String.UnicodeScalarView()
    var lastWasSpace = false
    for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
      let replacement: Unicode.Scalar
      switch scalar {
      case "/", ":":
        replacement = "-"
      default:
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
          replacement = " "
        default:
          replacement = scalar.properties.isWhitespace ? " " : scalar
        }
      }
      let isSpace = replacement == " "
      if isSpace && lastWasSpace { continue }
      scalars.append(replacement)
      lastWasSpace = isSpace
    }

    var result = String(scalars).trimmingCharacters(in: .whitespaces)
    while result.hasPrefix(".") {
      result.removeFirst()
      result = result.trimmingCharacters(in: .whitespaces)
    }
    result = truncate(result, maxBytes: maxStemBytes)
      .trimmingCharacters(in: .whitespaces)
    return result.isEmpty ? nil : result
  }

  /// The stem (name without extension) for a document: its sanitized title, or
  /// `"<untitled> <id>"` when the title sanitizes to nothing. The fallback
  /// depends only on the id, so it is stable across runs.
  public static func stem(for document: Document, untitled: String = "Document") -> String {
    sanitize(document.title) ?? "\(untitled) \(document.id)"
  }

  /// The extension for a document's file: `pdf` for the archive; the original
  /// file's extension for the original, falling back to `pdf` when the server
  /// gave no usable original file name.
  public static func fileExtension(
    for document: Document, content: FileProviderSettings.Content
  ) -> String {
    switch content {
    case .archive:
      return pdfExtension
    case .original:
      guard let name = document.originalFileName else { return pdfExtension }
      let ext = (name as NSString).pathExtension
      guard !ext.isEmpty, ext.count <= maxExtensionLength,
        ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
      else { return pdfExtension }
      return ext
    }
  }

  /// The full file name for a document, before collision handling.
  public static func fileName(
    for document: Document, content: FileProviderSettings.Content,
    untitled: String = "Document"
  ) -> String {
    compose(
      stem: stem(for: document, untitled: untitled),
      fileExtension: fileExtension(for: document, content: content))
  }

  static func compose(stem: String, fileExtension: String?) -> String {
    guard let fileExtension else { return stem }
    return "\(stem).\(fileExtension)"
  }

  /// One entry in a folder, for collision handling.
  public struct Entry: Hashable, Sendable {
    /// The name without extension.
    public var stem: String
    /// The extension, or `nil` for a folder.
    public var fileExtension: String?
    /// The text inside the collision suffix ` (#<disambiguator>)`, unique
    /// within the folder (a document id, or a folder's key).
    public var disambiguator: String

    public init(stem: String, fileExtension: String?, disambiguator: String) {
      self.stem = stem
      self.fileExtension = fileExtension
      self.disambiguator = disambiguator
    }
  }

  /// Final names for the entries of one folder, in the same order.
  ///
  /// Names are compared case-insensitively after NFC. Every entry whose name
  /// collides with another gets the suffix ` (#<disambiguator>)` before its
  /// extension; all colliding entries get it, not all but one, so the result
  /// does not depend on input order and a name changes only when its own
  /// collision state changes. The pass repeats until no names collide (a title
  /// can itself end in a suffix-like text).
  public static func resolveCollisions(_ entries: [Entry]) -> [String] {
    var stems = entries.map(\.stem)
    // The disambiguators are unique, so each pass makes every colliding group
    // distinct; a few passes settle any title that mimics a suffix.
    for _ in 0..<8 {
      var groups: [String: [Int]] = [:]
      for index in entries.indices {
        let name = compose(stem: stems[index], fileExtension: entries[index].fileExtension)
        groups[comparisonKey(name), default: []].append(index)
      }
      let colliding = groups.values.filter { $0.count > 1 }
      if colliding.isEmpty { break }
      for group in colliding {
        for index in group {
          stems[index] += " (#\(entries[index].disambiguator))"
        }
      }
    }
    return entries.indices.map {
      compose(stem: stems[$0], fileExtension: entries[$0].fileExtension)
    }
  }

  /// The key two names are compared by: NFC, then case-folded.
  public static func comparisonKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  private static func truncate(_ string: String, maxBytes: Int) -> String {
    guard string.utf8.count > maxBytes else { return string }
    var result = ""
    var bytes = 0
    for character in string {
      let size = character.utf8.count
      if bytes + size > maxBytes { break }
      result.append(character)
      bytes += size
    }
    return result
  }
}
