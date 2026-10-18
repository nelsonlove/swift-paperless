//
//  ItemIdentifier.swift
//  FileProviderCore
//

import Foundation

/// The key of a folder in the canonical tree. Each case belongs to one
/// ``FolderLayout``; `nil` ids are the "No correspondent" / "No document type"
/// folders.
public enum FolderKey: Hashable, Sendable {
  /// `dir:correspondent:<id|none>`
  case correspondent(UInt?)
  /// `dir:documentType:<id|none>`
  case documentType(UInt?)
  /// `dir:year:<year>`
  case year(Int)
  /// `dir:correspondentYear:<id|none>` (the correspondent level) and
  /// `dir:correspondentYear:<id|none>/<year>` (a year inside it).
  case correspondentYear(correspondent: UInt?, year: Int?)

  /// The text for a missing correspondent or document type, both in folder
  /// identifiers (`dir:correspondent:none`) and in the tree's collision
  /// suffixes and fallback names. The one spelling of it.
  static let noneToken = "none"

  /// An id as written in identifiers and suffixes: its decimal form, or
  /// ``noneToken``.
  static func token(for id: UInt?) -> String {
    id.map { String($0) } ?? noneToken
  }

  /// The layout this folder belongs to.
  public var layout: FolderLayout {
    switch self {
    case .correspondent: .correspondent
    case .documentType: .documentType
    case .year: .year
    case .correspondentYear: .correspondentYear
    }
  }
}

/// A typed File Provider item identifier with a lossless string codec.
///
/// The domain scopes the server, so no server id appears here. The extension
/// maps ``root`` to `NSFileProviderItemIdentifier.rootContainer` itself; this
/// package does not import FileProvider. The string forms are:
///
/// - `root`
/// - `dir:<layout>:<key>`: a canonical folder, for example `dir:correspondent:12`,
///   `dir:correspondent:none`, `dir:year:2026`, `dir:correspondentYear:12/2026`
/// - `doc:<id>`: a canonical document
/// - `browse:tag`, `browse:correspondent`, `browse:type`: the browse roots
/// - `tag:<id>`, `corr:<id>`, `type:<id>`: folders inside a browse root
/// - `tag:<id>/doc:<id>`, `corr:<id>/doc:<id>`, `type:<id>/doc:<id>`: secondary
///   appearances of a document
///
/// `init?(stringValue:)` accepts exactly the strings `stringValue` produces
/// (ids in canonical decimal form, no leading zeros or signs), so the round
/// trip is lossless in both directions.
///
/// The type is deliberately not `RawRepresentable`: the standard library's
/// `RawRepresentable` defaults would make `==` and `hash(into:)` build the
/// string for every dictionary lookup. Equality and hashing are the
/// synthesized ones, which switch on the cases and their payloads.
public enum ItemIdentifier: Hashable, Sendable {
  case root
  case folder(FolderKey)
  case document(UInt)
  case browseRoot(BrowseFolder)
  case browseFolder(BrowseFolder, id: UInt)
  case appearance(BrowseFolder, folderID: UInt, documentID: UInt)

  /// The document this item shows, for canonical documents and secondary
  /// appearances.
  public var documentID: UInt? {
    switch self {
    case .document(let id): id
    case .appearance(_, _, let documentID): documentID
    default: nil
    }
  }

  /// Whether the item is a container (root or any folder).
  public var isContainer: Bool {
    documentID == nil
  }
}

extension ItemIdentifier {

  /// The identifier's string form, as handed to File Provider.
  public var stringValue: String {
    switch self {
    case .root:
      return "root"
    case .folder(let key):
      return "dir:\(key.layout.rawValue):\(Self.encode(key))"
    case .document(let id):
      return "doc:\(id)"
    case .browseRoot(let browse):
      return "browse:\(browse.rawValue)"
    case .browseFolder(let browse, let id):
      return "\(browse.folderPrefix):\(id)"
    case .appearance(let browse, let folderID, let documentID):
      return "\(browse.folderPrefix):\(folderID)/doc:\(documentID)"
    }
  }

  /// Parses a string from ``stringValue``; `nil` for anything else.
  public init?(stringValue string: String) {
    if string == "root" {
      self = .root
      return
    }

    guard let colon = string.firstIndex(of: ":") else { return nil }
    let head = string[..<colon]
    let tail = string[string.index(after: colon)...]

    switch head {
    case "doc":
      guard let id = Self.parseID(tail) else { return nil }
      self = .document(id)

    case "browse":
      guard let browse = BrowseFolder(rawValue: String(tail)) else { return nil }
      self = .browseRoot(browse)

    case "dir":
      guard let separator = tail.firstIndex(of: ":"),
        let layout = FolderLayout(rawValue: String(tail[..<separator])),
        let key = Self.decodeKey(layout: layout, tail[tail.index(after: separator)...])
      else { return nil }
      self = .folder(key)

    default:
      guard let browse = BrowseFolder(folderPrefix: head) else { return nil }
      let parts = tail.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      guard let folderID = Self.parseID(parts[0]) else { return nil }
      if parts.count == 1 {
        self = .browseFolder(browse, id: folderID)
        return
      }
      let documentPart = parts[1]
      guard documentPart.hasPrefix("doc:"),
        let documentID = Self.parseID(documentPart.dropFirst(4))
      else { return nil }
      self = .appearance(browse, folderID: folderID, documentID: documentID)
    }
  }

  private static func encode(_ key: FolderKey) -> String {
    switch key {
    case .correspondent(let id), .documentType(let id):
      return FolderKey.token(for: id)
    case .year(let year):
      return String(year)
    case .correspondentYear(let correspondent, let year):
      let base = FolderKey.token(for: correspondent)
      guard let year else { return base }
      return "\(base)/\(year)"
    }
  }

  private static func decodeKey(layout: FolderLayout, _ raw: Substring) -> FolderKey? {
    switch layout {
    case .correspondent:
      guard let id = parseOptionalID(raw) else { return nil }
      return .correspondent(id.value)
    case .documentType:
      guard let id = parseOptionalID(raw) else { return nil }
      return .documentType(id.value)
    case .year:
      guard let year = parseYear(raw) else { return nil }
      return .year(year)
    case .correspondentYear:
      let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      guard let id = parseOptionalID(parts[0]) else { return nil }
      if parts.count == 1 {
        return .correspondentYear(correspondent: id.value, year: nil)
      }
      guard let year = parseYear(parts[1]) else { return nil }
      return .correspondentYear(correspondent: id.value, year: year)
    case .flat:
      // The flat layout has no folders.
      return nil
    }
  }

  /// The wrapper distinguishes "parsed as none" from "failed to parse".
  private struct OptionalID {
    var value: UInt?
  }

  private static func parseOptionalID(_ raw: Substring) -> OptionalID? {
    if raw == FolderKey.noneToken { return OptionalID(value: nil) }
    guard let id = parseID(raw) else { return nil }
    return OptionalID(value: id)
  }

  /// A year may be negative (a `created` date before year 1), so an optional
  /// leading `-` is accepted; `-0` is not, since `String(0)` is `0`.
  private static func parseYear(_ raw: Substring) -> Int? {
    let digits = raw.hasPrefix("-") ? raw.dropFirst() : raw
    guard isCanonicalDecimal(digits), raw != "-0" else { return nil }
    return Int(raw)
  }

  private static func parseID(_ raw: Substring) -> UInt? {
    guard isCanonicalDecimal(raw) else { return nil }
    return UInt(raw)
  }

  /// ASCII digits only, no sign, no leading zero (except "0" itself), so every
  /// accepted string is the one `String(value)` produces.
  private static func isCanonicalDecimal(_ raw: Substring) -> Bool {
    guard let first = raw.first else { return false }
    guard raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
    return first != "0" || raw.count == 1
  }
}

extension ItemIdentifier: CustomStringConvertible {
  public var description: String { stringValue }
}

extension ItemIdentifier: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let value = ItemIdentifier(stringValue: raw) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid item identifier \(raw)")
    }
    self = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(stringValue)
  }
}

extension ItemIdentifier: CodingKeyRepresentable {
  public var codingKey: any CodingKey {
    IdentifierCodingKey(stringValue: stringValue)
  }

  public init?<T: CodingKey>(codingKey: T) {
    self.init(stringValue: codingKey.stringValue)
  }
}

private struct IdentifierCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }

  init(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue _: Int) {
    nil
  }
}
