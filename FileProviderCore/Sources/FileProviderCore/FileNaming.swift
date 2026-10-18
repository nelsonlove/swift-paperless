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

  /// The longest extension kept, in characters (and in bytes when a name is
  /// composed).
  public static let maxExtensionLength = 16

  /// The extension used for archived documents and as the fallback.
  public static let pdfExtension = "pdf"

  /// Format characters (general category Cf) that ``sanitize(_:)`` keeps:
  /// U+200C ZERO WIDTH NON-JOINER and U+200D ZERO WIDTH JOINER, which emoji
  /// sequences and words in Persian and Indic scripts need, and the emoji tag
  /// characters U+E0020 to U+E007F, which spell subdivision flags such as
  /// Scotland's. Every other format character is dropped: the bidi controls
  /// (U+200E, U+200F, U+202A to U+202E, U+2066 to U+2069), U+200B, U+FEFF and
  /// the rest, which are invisible and can disguise a name.
  static func keepsFormatCharacter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x200C, 0x200D, 0xE0020...0xE007F: true
    default: false
    }
  }

  /// Makes a string safe to use as one path component.
  ///
  /// Replaces `/` and `:` with `-`, replaces control characters and line or
  /// paragraph separators with a space, drops format characters except those
  /// ``keepsFormatCharacter(_:)`` names, collapses runs of whitespace, applies
  /// Unicode NFC to the result (after the drops, so the name is always NFC),
  /// trims whitespace and leading dots (a leading dot hides the file; checked
  /// per Unicode scalar, so a dot followed by a combining mark counts), and
  /// caps the length at ``maxStemBytes``. Returns `nil` when nothing is left.
  public static func sanitize(_ raw: String) -> String? {
    var scalars = String.UnicodeScalarView()
    var lastWasSpace = false
    for scalar in raw.unicodeScalars {
      let replacement: Unicode.Scalar
      switch scalar {
      case "/", ":":
        replacement = "-"
      default:
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
          replacement = " "
        case .format where !keepsFormatCharacter(scalar):
          continue
        default:
          replacement = scalar.properties.isWhitespace ? " " : scalar
        }
      }
      let isSpace = replacement == " "
      if isSpace && lastWasSpace { continue }
      scalars.append(replacement)
      lastWasSpace = isSpace
    }

    // NFC after the drops: a dropped character between a letter and its
    // combining mark would otherwise leave them uncomposed.
    var result = String(scalars).precomposedStringWithCanonicalMapping
    result = stripLeadingDots(result.trimmingCharacters(in: .whitespaces))
    result = truncate(result, maxBytes: maxStemBytes).trimmingCharacters(in: .whitespaces)
    // Removing a leading scalar or cutting at a character boundary keeps NFC;
    // normalize once more so that holds by construction.
    result = result.precomposedStringWithCanonicalMapping
    return result.isEmpty ? nil : result
  }

  /// Removes leading `.` scalars and the whitespace after them, repeatedly.
  /// Works on scalars, not characters, because `.` followed by a combining
  /// mark is one character that `hasPrefix(".")` does not match.
  private static func stripLeadingDots(_ string: String) -> String {
    var scalars = Substring(string).unicodeScalars
    while scalars.first == "." {
      scalars.removeFirst()
      while let first = scalars.first, first.properties.isWhitespace {
        scalars.removeFirst()
      }
    }
    return String(scalars)
  }

  /// The stem (name without extension) for a document: its sanitized title, or
  /// the sanitized `"<untitled> <id>"` when the title sanitizes to nothing
  /// (just the id if the label sanitizes to nothing too). The fallback depends
  /// only on the label and the id, so it is stable across runs.
  public static func stem(for document: Document, untitled: String = "Document") -> String {
    sanitize(document.title) ?? sanitize("\(untitled) \(document.id)") ?? String(document.id)
  }

  /// The variant the server actually serves for a document. A document with
  /// no archive (`archivedFileName == nil`, for example an image or office
  /// file paperless did not convert) gets its original even when the archive
  /// is asked for, as `ApiRepository` does for downloads.
  public static func servedContent(
    for document: Document, requested: FileProviderSettings.Content
  ) -> FileProviderSettings.Content {
    requested == .archive && document.archivedFileName == nil ? .original : requested
  }

  /// The extension for a document's file: `pdf` for the archive; the original
  /// file's extension for the original (also when the archive is asked for
  /// but the document has none), falling back to `pdf` when the server gave
  /// no usable original file name.
  public static func fileExtension(
    for document: Document, content: FileProviderSettings.Content
  ) -> String {
    switch servedContent(for: document, requested: content) {
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
    compose(stem: stem, suffix: "", fileExtension: fileExtension)
  }

  /// One entry in a folder, for collision handling.
  public struct Entry: Hashable, Sendable {
    /// The name without extension.
    public var stem: String
    /// The extension, or `nil` for a folder.
    public var fileExtension: String?
    /// The text inside the usual collision suffix ` (#<disambiguator>)` (a
    /// document id, or a folder's key).
    public var disambiguator: String
    /// A key unique within the folder (the item identifier's string), used
    /// for the fallback suffix and to order the last resort.
    public var uniqueKey: String
    /// Whether the entry keeps its name when it collides with entries that do
    /// not (the browse roots); the others take the suffix.
    public var keepsName: Bool

    public init(
      stem: String, fileExtension: String?, disambiguator: String,
      uniqueKey: String? = nil, keepsName: Bool = false
    ) {
      self.stem = stem
      self.fileExtension = fileExtension
      self.disambiguator = disambiguator
      self.uniqueKey = uniqueKey ?? disambiguator
      self.keepsName = keepsName
    }
  }

  /// The longest final name, in UTF-8 bytes (the APFS limit).
  public static let maxNameBytes = 255

  /// Final names for the entries of one folder, in the same order. The names
  /// are always unique (compared case-insensitively after NFC) and at most
  /// ``maxNameBytes`` long; the stem is cut on a character boundary to make
  /// room for a suffix and the extension.
  ///
  /// First, every entry whose name collides with another gets the suffix
  /// ` (#<disambiguator>)` before its extension, repeated until no new entry
  /// needs one. All colliding entries get it, not all but one, so this step
  /// does not depend on input order and a name changes only when its own
  /// collision state changes. An entry with `keepsName` is left alone when it
  /// is the only such entry in its collision group.
  ///
  /// What still collides after that (a title that mimics a suffix, or a
  /// repeated disambiguator) is settled in a fixed order: `keepsName` entries
  /// first, then by `uniqueKey`. The first keeps its name; each later one gets
  /// ` (#<hash>-<n>)`, where `<hash>` is a short stable hash of `uniqueKey`
  /// (so no `/` or `:` from an identifier reaches the name) and `<n>` is the
  /// first counter from 1 that gives a free name.
  ///
  /// That last step always ends with a free name within `entries.count`
  /// tries: the suffix and the extension are reserved before the stem is cut,
  /// so the counter is never cut away, and two counters give two different
  /// names (they differ in the digits before the closing parenthesis, or one
  /// has a `-` where the other has a digit). At most `entries.count - 1`
  /// names are taken, so one of the first `entries.count` counters is free.
  public static func resolveCollisions(_ entries: [Entry]) -> [String] {
    resolveCollisions(entries, keyOf: comparisonKey)
  }

  /// The implementation, with the comparison key injectable so tests can
  /// count how often it runs: once per entry, and once more per name change.
  static func resolveCollisions(_ entries: [Entry], keyOf: (String) -> String) -> [String] {
    var suffixes = [String](repeating: "", count: entries.count)
    func compose(_ index: Int) -> String {
      FileNaming.compose(
        stem: entries[index].stem, suffix: suffixes[index],
        fileExtension: entries[index].fileExtension)
    }
    // Each name and its comparison key are computed once and recomputed only
    // when the entry's suffix changes.
    var names = entries.indices.map(compose)
    var keys = names.map(keyOf)
    func setSuffix(_ index: Int, _ suffix: String) {
      suffixes[index] = suffix
      names[index] = compose(index)
      keys[index] = keyOf(names[index])
    }
    func collisionGroups() -> [[Int]] {
      var groups: [String: [Int]] = [:]
      for index in entries.indices {
        groups[keys[index], default: []].append(index)
      }
      return groups.values.filter { $0.count > 1 }
    }

    // Entries only ever move from no suffix to a suffix, so this ends after
    // at most `entries.count` rounds.
    var changed = true
    while changed {
      changed = false
      for group in collisionGroups() {
        let keepers = group.filter { entries[$0].keepsName && suffixes[$0].isEmpty }
        for index in group where suffixes[index].isEmpty {
          if keepers.count == 1, keepers[0] == index { continue }
          setSuffix(index, " (#\(suffixToken(entries[index].disambiguator)))")
          changed = true
        }
      }
    }

    let remaining = collisionGroups().flatMap { $0 }
    if remaining.isEmpty {
      return names
    }

    let remainingSet = Set(remaining)
    var used = Set(entries.indices.filter { !remainingSet.contains($0) }.map { keys[$0] })
    let ordered = remaining.sorted { lhs, rhs in
      if entries[lhs].keepsName != entries[rhs].keepsName { return entries[lhs].keepsName }
      if entries[lhs].uniqueKey != entries[rhs].uniqueKey {
        return entries[lhs].uniqueKey < entries[rhs].uniqueKey
      }
      return lhs < rhs
    }
    for index in ordered {
      if used.insert(keys[index]).inserted { continue }
      let hash = stableHash(entries[index].uniqueKey)
      var settled = false
      for counter in 1...entries.count {
        setSuffix(index, " (#\(hash)-\(counter))")
        if used.insert(keys[index]).inserted {
          settled = true
          break
        }
      }
      // Unreachable by the argument in the doc comment.
      assert(settled, "no free name for \(entries[index].uniqueKey)")
    }
    return names
  }

  /// The longest disambiguator text kept in a ` (#<disambiguator>)` suffix.
  static let maxDisambiguatorBytes = 40

  /// A disambiguator made safe for a name: sanitized (no `/` or `:`) and
  /// short, or a stable hash when nothing usable is left.
  static func suffixToken(_ disambiguator: String) -> String {
    guard let clean = sanitize(disambiguator) else { return stableHash(disambiguator) }
    guard clean.utf8.count > maxDisambiguatorBytes else { return clean }
    return stableHash(disambiguator)
  }

  /// FNV-1a over the UTF-8 bytes, folded to 32 bits, as 8 lowercase hex
  /// digits. Stable across runs and processes, unlike `Hasher`.
  static func stableHash(_ string: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01b3
    }
    let folded = UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
    let hex = String(folded, radix: 16)
    return String(repeating: "0", count: 8 - hex.count) + hex
  }

  /// Joins a stem, a suffix and an extension so the whole name fits in
  /// ``maxNameBytes``. The suffix and the extension are reserved first (the
  /// extension cut to ``maxExtensionLength`` bytes), and only the stem is cut,
  /// on a character boundary, so a suffix is never cut away.
  static func compose(stem: String, suffix: String, fileExtension: String?) -> String {
    let tail =
      suffix + (fileExtension.map { ".\(truncate($0, maxBytes: maxExtensionLength))" } ?? "")
    let budget = max(0, maxNameBytes - tail.utf8.count)
    var cut = truncate(stem, maxBytes: budget)
    if cut.utf8.count < stem.utf8.count {
      cut = cut.trimmingCharacters(in: .whitespaces)
    }
    return cut + tail
  }

  /// The key two names are compared by: NFC, then case-folded.
  public static func comparisonKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive], locale: comparisonLocale)
  }

  private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

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
