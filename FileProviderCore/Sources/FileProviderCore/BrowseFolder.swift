//
//  BrowseFolder.swift
//  FileProviderCore
//

import Foundation

/// An optional folder beside the canonical tree in a domain's root.
///
/// Its children are secondary appearances of documents (for example
/// `tag:3/doc:12`), which share the canonical item's content but have their own
/// identifiers. The raw value is used in settings and in the `browse:<raw>`
/// identifier, so it must never change once shipped.
public enum BrowseFolder: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
  /// "By tag", nested by `Tag.parent`.
  case tag
  /// "By correspondent".
  case correspondent
  /// "By type".
  case documentType = "type"

  /// The prefix of the folder identifiers inside this browse folder
  /// (`tag:<id>`, `corr:<id>`, `type:<id>`).
  public var folderPrefix: String {
    switch self {
    case .tag: "tag"
    case .correspondent: "corr"
    case .documentType: "type"
    }
  }

  init?(folderPrefix: some StringProtocol) {
    switch folderPrefix {
    case "tag": self = .tag
    case "corr": self = .correspondent
    case "type": self = .documentType
    default: return nil
    }
  }

  private var sortIndex: Int {
    Self.allCases.firstIndex(of: self) ?? 0
  }

  public static func < (lhs: BrowseFolder, rhs: BrowseFolder) -> Bool {
    lhs.sortIndex < rhs.sortIndex
  }
}
