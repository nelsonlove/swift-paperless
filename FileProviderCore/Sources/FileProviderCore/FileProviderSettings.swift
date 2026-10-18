//
//  FileProviderSettings.swift
//  FileProviderCore
//

import Foundation

/// Per-server settings for how a library is shown in the Files app.
///
/// Decoding is lenient: a missing or unknown value (for example a layout written
/// by a newer build) falls back to the default for that field instead of
/// failing, so the extension always has settings to work with.
public struct FileProviderSettings: Codable, Equatable, Hashable, Sendable {
  /// Which file a document's item serves.
  public enum Content: String, Codable, CaseIterable, Hashable, Sendable {
    /// The archived PDF that paperless generates.
    case archive
    /// The file as it was uploaded.
    case original
  }

  public var layout: FolderLayout
  public var browseFolders: Set<BrowseFolder>
  public var content: Content

  public static let `default` = FileProviderSettings()

  public init(
    layout: FolderLayout = .correspondent,
    browseFolders: Set<BrowseFolder> = Set(BrowseFolder.allCases),
    content: Content = .archive
  ) {
    self.layout = layout
    self.browseFolders = browseFolders
    self.content = content
  }

  private enum CodingKeys: String, CodingKey {
    case layout
    case browseFolders
    case content
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = FileProviderSettings()

    let layoutRaw = try? container.decodeIfPresent(String.self, forKey: .layout)
    layout = layoutRaw.flatMap(FolderLayout.init(rawValue:)) ?? defaults.layout

    if let raws = try? container.decodeIfPresent([String].self, forKey: .browseFolders) {
      browseFolders = Set(raws.compactMap(BrowseFolder.init(rawValue:)))
    } else {
      browseFolders = defaults.browseFolders
    }

    let contentRaw = try? container.decodeIfPresent(String.self, forKey: .content)
    content = contentRaw.flatMap(Content.init(rawValue:)) ?? defaults.content
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(layout, forKey: .layout)
    // Sorted, so the encoded bytes are stable.
    try container.encode(browseFolders.sorted().map(\.rawValue), forKey: .browseFolders)
    try container.encode(content, forKey: .content)
  }
}
