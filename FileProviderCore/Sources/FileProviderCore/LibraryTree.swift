//
//  LibraryTree.swift
//  FileProviderCore
//

import DataModel
import Foundation

/// One node of a ``LibraryTree``: a folder or a document file.
public struct TreeItem: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case folder
    case document
  }

  public var identifier: ItemIdentifier
  /// The parent container. The root is its own parent, as in File Provider.
  public var parent: ItemIdentifier
  /// The final name shown in Files, collision suffix and extension included.
  /// Empty for the root, whose name is the domain's display name.
  public var name: String
  public var kind: Kind
  /// Changes when the item's content changes. For documents it covers the
  /// variant actually served (the original when there is no archive), the
  /// current version id and `modified`; for folders it is
  /// empty (a folder's name and parent are compared on their own).
  public var version: String

  public var isFolder: Bool { kind == .folder }

  public init(
    identifier: ItemIdentifier, parent: ItemIdentifier, name: String, kind: Kind,
    version: String
  ) {
    self.identifier = identifier
    self.parent = parent
    self.name = name
    self.kind = kind
    self.version = version
  }
}

/// The user-visible names the tree makes up itself. English defaults; the
/// extension can pass localized strings.
public struct TreeLabels: Hashable, Sendable {
  public var byTag: String
  public var byCorrespondent: String
  public var byDocumentType: String
  public var noCorrespondent: String
  public var noDocumentType: String
  /// Prefix for a tag whose id is not in the tag list: "Tag 7".
  public var unknownTag: String
  /// Prefix for a correspondent whose id is not in the list: "Correspondent 7".
  public var unknownCorrespondent: String
  /// Prefix for a document type whose id is not in the list: "Document type 7".
  public var unknownDocumentType: String
  /// Prefix for a document whose title is empty: "Document 12".
  public var untitledDocument: String

  public init(
    byTag: String = "By tag",
    byCorrespondent: String = "By correspondent",
    byDocumentType: String = "By type",
    noCorrespondent: String = "No correspondent",
    noDocumentType: String = "No document type",
    unknownTag: String = "Tag",
    unknownCorrespondent: String = "Correspondent",
    unknownDocumentType: String = "Document type",
    untitledDocument: String = "Document"
  ) {
    self.byTag = byTag
    self.byCorrespondent = byCorrespondent
    self.byDocumentType = byDocumentType
    self.noCorrespondent = noCorrespondent
    self.noDocumentType = noDocumentType
    self.unknownTag = unknownTag
    self.unknownCorrespondent = unknownCorrespondent
    self.unknownDocumentType = unknownDocumentType
    self.untitledDocument = untitledDocument
  }
}

/// The whole folder tree of one domain, built in memory from the cached
/// library and the server's ``FileProviderSettings``.
///
/// The root holds the canonical tree (shaped by ``FolderLayout``, every
/// document exactly once as `doc:<id>`) and the enabled browse folders, whose
/// documents are secondary appearances. Folders exist only while they hold
/// something; the root and the enabled browse roots always exist. Documents
/// with no correspondent or type go to the "No correspondent" / "No document
/// type" folder, and a referenced id missing from the element lists gets a
/// folder with a fallback name, so its identifier does not change when the
/// list catches up. "By tag" nests by `Tag.parent`; tags on a parent cycle are
/// shown at the top level.
public struct LibraryTree: Sendable {
  public let settings: FileProviderSettings

  private var items: [ItemIdentifier: TreeItem] = [:]
  private var childIDs: [ItemIdentifier: [ItemIdentifier]] = [:]
  private var documentsByID: [UInt: Document] = [:]

  public init(
    documents: [Document],
    tags: [Tag],
    correspondents: [Correspondent],
    documentTypes: [DocumentType],
    // Unused until the storage-path layout lands; accepted now so callers do
    // not change then.
    storagePaths: [StoragePath] = [],
    settings: FileProviderSettings = .default,
    labels: TreeLabels = TreeLabels()
  ) {
    self.settings = settings
    var builder = Builder(
      tags: tags, correspondents: correspondents, documentTypes: documentTypes,
      settings: settings, labels: labels)

    // A duplicated id keeps one copy, chosen by `isPreferred`, so the result
    // does not depend on input order.
    for document in documents {
      if let kept = documentsByID[document.id], !LibraryTree.isPreferred(document, over: kept) {
        continue
      }
      documentsByID[document.id] = document
    }
    // The order of `add` calls does not matter: every folder's name comes
    // from its key alone, and names are settled per folder in `finish`.
    for document in documentsByID.values {
      builder.add(document)
    }

    (items, childIDs) = builder.finish()
  }

  /// Which of two copies of one document id to keep: the later `modified`
  /// (none counts as oldest), then the greater title, then the greater full
  /// description, which is a total order over the values that build the tree.
  static func isPreferred(_ candidate: Document, over kept: Document) -> Bool {
    let candidateModified = candidate.modified ?? .distantPast
    let keptModified = kept.modified ?? .distantPast
    if candidateModified != keptModified { return candidateModified > keptModified }
    if candidate.title != kept.title { return candidate.title > kept.title }
    return String(describing: candidate) > String(describing: kept)
  }

  /// Elements keyed by id. When an id appears more than once, the copy with
  /// the greater name wins, then the one with the greater full description,
  /// so the choice does not depend on input order (as for documents).
  static func byID<Element: Identifiable>(
    _ elements: [Element], name: KeyPath<Element, String>
  ) -> [Element.ID: Element] {
    var result: [Element.ID: Element] = [:]
    for element in elements {
      if let kept = result[element.id] {
        let (newName, keptName) = (element[keyPath: name], kept[keyPath: name])
        if newName != keptName {
          guard newName > keptName else { continue }
        } else if String(describing: element) <= String(describing: kept) {
          continue
        }
      }
      result[element.id] = element
    }
    return result
  }

  /// The year of a document's `created` date, independent of the current
  /// time zone.
  ///
  /// `created` is date-only on the server. `DateOnlyCodable` decodes it as
  /// midnight in the time zone current at decode time, and the cache keeps the
  /// absolute `Date`, so reading it with a later zone can land on the
  /// previous or next day (and so the previous or next year on 1 January or
  /// 31 December).
  ///
  /// A local midnight at offset `z` is the UTC midnight of the same calendar
  /// day minus `z`. Adding 13.5 hours and taking the UTC day recovers that day
  /// for every offset from just above UTC-10:30 up to UTC+13:30: that is every
  /// populated zone from Hawaii (UTC-10) and the Marquesas (UTC-9:30) to
  /// Samoa, Tonga and New Zealand summer time (UTC+13). The zones it misses
  /// are UTC-12 and UTC-11 (Baker Island, American Samoa, Niue), Chatham
  /// summer time (UTC+13:45) and Kiritimati (UTC+14). UTC-10 and UTC+14 cannot
  /// both be covered: midnight on 1 January in Hawaii is the same instant as
  /// midnight on 2 January in Kiritimati, so one rule must give one answer
  /// for both; this one keeps Hawaii.
  public static func createdYear(_ created: Date) -> Int {
    let shift: TimeInterval = 13.5 * 3600
    let day: TimeInterval = 86_400
    let days = ((created.timeIntervalSince1970 + shift) / day).rounded(.down)
    let midnight = Date(timeIntervalSince1970: days * day)
    return utcCalendar.component(.year, from: midnight)
  }

  private static let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// The item for an identifier, or `nil` if the tree has no such item.
  public func item(for identifier: ItemIdentifier) -> TreeItem? {
    items[identifier]
  }

  /// The parent of an item, or `nil` if the tree has no such item. The root is
  /// its own parent.
  public func parent(of identifier: ItemIdentifier) -> ItemIdentifier? {
    items[identifier]?.parent
  }

  /// The children of a container, folders first, then documents, each sorted
  /// by name. `nil` if the identifier is not a container in this tree.
  public func children(of identifier: ItemIdentifier) -> [TreeItem]? {
    guard let item = items[identifier], item.isFolder else { return nil }
    return (childIDs[identifier] ?? []).compactMap { items[$0] }
  }

  /// The cached document a canonical item or secondary appearance shows.
  /// `nil` when the identifier is not in the tree, as for ``item(for:)``,
  /// even if the document it names exists elsewhere in the tree.
  public func document(for identifier: ItemIdentifier) -> Document? {
    guard items[identifier] != nil else { return nil }
    return identifier.documentID.flatMap { documentsByID[$0] }
  }

  /// Every item except the root, in breadth-first order from the root.
  public var allItems: [TreeItem] {
    traverse { _ in true }
  }

  /// Every folder plus every canonical document, never a secondary appearance
  /// and never the root, in breadth-first order (folders before their
  /// children).
  public var workingSet: [TreeItem] {
    traverse { item in
      if case .appearance = item.identifier { return false }
      return true
    }
  }

  private func traverse(including include: (TreeItem) -> Bool) -> [TreeItem] {
    var result: [TreeItem] = []
    var queue: [ItemIdentifier] = [.root]
    var index = 0
    while index < queue.count {
      let current = queue[index]
      index += 1
      for child in childIDs[current] ?? [] {
        guard let item = items[child] else { continue }
        if include(item) { result.append(item) }
        if item.isFolder { queue.append(child) }
      }
    }
    return result
  }
}

// MARK: - Building

extension LibraryTree {
  private struct Node {
    var identifier: ItemIdentifier
    var parent: ItemIdentifier
    var stem: String
    var fileExtension: String?
    var disambiguator: String
    var kind: TreeItem.Kind
    var version: String
    /// Browse roots keep their label; a canonical folder of the same name
    /// takes the collision suffix instead.
    var keepsName = false
  }

  private struct Builder {
    let settings: FileProviderSettings
    let labels: TreeLabels
    let tagsByID: [UInt: Tag]
    let tagParents: [UInt: UInt]
    let correspondentsByID: [UInt: Correspondent]
    let documentTypesByID: [UInt: DocumentType]

    var nodes: [ItemIdentifier: Node] = [:]

    init(
      tags: [Tag], correspondents: [Correspondent], documentTypes: [DocumentType],
      settings: FileProviderSettings, labels: TreeLabels
    ) {
      self.settings = settings
      self.labels = labels
      tagsByID = LibraryTree.byID(tags, name: \.name)
      tagParents = Builder.effectiveTagParents(tagsByID)
      correspondentsByID = LibraryTree.byID(correspondents, name: \.name)
      documentTypesByID = LibraryTree.byID(documentTypes, name: \.name)

      for browse in settings.browseFolders {
        let label: String =
          switch browse {
          case .tag: labels.byTag
          case .correspondent: labels.byCorrespondent
          case .documentType: labels.byDocumentType
          }
        addFolder(
          .browseRoot(browse), parent: .root, disambiguator: browse.rawValue
        ) { _ in FileNaming.sanitize(label) ?? browse.rawValue }
        nodes[.browseRoot(browse)]?.keepsName = true
      }
    }

    /// Each tag's parent for display. A parent missing from the list is
    /// dropped, and every tag on a cycle (a self-parent included) is moved to
    /// the top level, so every chain ends at the root.
    static func effectiveTagParents(_ tags: [UInt: Tag]) -> [UInt: UInt] {
      var parents: [UInt: UInt] = [:]
      for (id, tag) in tags {
        if let parent = tag.parent, tags[parent] != nil {
          parents[id] = parent
        }
      }
      let limit = parents.count
      var onCycle = Set<UInt>()
      for id in parents.keys {
        var current = parents[id]
        var steps = 0
        while let next = current, steps <= limit {
          if next == id {
            onCycle.insert(id)
            break
          }
          current = parents[next]
          steps += 1
        }
      }
      for id in onCycle {
        parents[id] = nil
      }
      return parents
    }

    mutating func add(_ document: Document) {
      let stem = FileNaming.stem(for: document, untitled: labels.untitledDocument)
      let fileExtension = FileNaming.fileExtension(for: document, content: settings.content)
      let modified = document.modified.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
      let served = FileNaming.servedContent(for: document, requested: settings.content)
      let version = "\(served.rawValue):\(document.currentVersionID)/\(modified)"

      func addDocument(_ identifier: ItemIdentifier, parent: ItemIdentifier) {
        nodes[identifier] = Node(
          identifier: identifier, parent: parent, stem: stem, fileExtension: fileExtension,
          disambiguator: String(document.id), kind: .document, version: version)
      }

      addDocument(.document(document.id), parent: canonicalParent(of: document))

      if settings.browseFolders.contains(.tag) {
        for tagID in Set(document.tags) {
          let folder = ensureTagFolder(tagID)
          addDocument(
            .appearance(.tag, folderID: tagID, documentID: document.id), parent: folder)
        }
      }
      if settings.browseFolders.contains(.correspondent), let id = document.correspondent {
        let folder = ItemIdentifier.browseFolder(.correspondent, id: id)
        addFolder(
          folder, parent: .browseRoot(.correspondent), disambiguator: String(id)
        ) { $0.correspondentName(id) }
        addDocument(
          .appearance(.correspondent, folderID: id, documentID: document.id), parent: folder)
      }
      if settings.browseFolders.contains(.documentType), let id = document.documentType {
        let folder = ItemIdentifier.browseFolder(.documentType, id: id)
        addFolder(
          folder, parent: .browseRoot(.documentType), disambiguator: String(id)
        ) { $0.documentTypeName(id) }
        addDocument(
          .appearance(.documentType, folderID: id, documentID: document.id), parent: folder)
      }
    }

    private mutating func canonicalParent(of document: Document) -> ItemIdentifier {
      switch settings.layout {
      case .flat:
        return .root

      case .correspondent:
        let id = document.correspondent
        let folder = ItemIdentifier.folder(.correspondent(id))
        addFolder(
          folder, parent: .root, disambiguator: key(id)
        ) { $0.correspondentName(id) }
        return folder

      case .documentType:
        let id = document.documentType
        let folder = ItemIdentifier.folder(.documentType(id))
        addFolder(
          folder, parent: .root, disambiguator: key(id)
        ) { $0.documentTypeName(id) }
        return folder

      case .year:
        let year = LibraryTree.createdYear(document.created)
        let folder = ItemIdentifier.folder(.year(year))
        addFolder(folder, parent: .root, disambiguator: String(year)) { _ in String(year) }
        return folder

      case .correspondentYear:
        let id = document.correspondent
        let year = LibraryTree.createdYear(document.created)
        let outer = ItemIdentifier.folder(.correspondentYear(correspondent: id, year: nil))
        addFolder(outer, parent: .root, disambiguator: key(id)) { $0.correspondentName(id) }
        let inner = ItemIdentifier.folder(.correspondentYear(correspondent: id, year: year))
        addFolder(inner, parent: outer, disambiguator: String(year)) { _ in String(year) }
        return inner
      }
    }

    /// Adds the tag's folder and every ancestor folder, and returns the tag's.
    private mutating func ensureTagFolder(_ tagID: UInt) -> ItemIdentifier {
      let folder = ItemIdentifier.browseFolder(.tag, id: tagID)
      var current: UInt? = tagID
      // Effective parents have no cycles, so this ends at the top level; the
      // bound is a second guard.
      var steps = 0
      while let id = current, steps <= tagParents.count {
        let identifier = ItemIdentifier.browseFolder(.tag, id: id)
        if nodes[identifier] != nil { break }
        let parent: ItemIdentifier =
          tagParents[id].map { .browseFolder(.tag, id: $0) } ?? .browseRoot(.tag)
        addFolder(identifier, parent: parent, disambiguator: String(id)) { $0.tagName(id) }
        current = tagParents[id]
        steps += 1
      }
      return folder
    }

    /// Adds a folder unless it exists. `stem` returns the already sanitized
    /// stem and is only called for a new folder; it gets the builder as an
    /// argument rather than capturing it, which a mutating method may not.
    private mutating func addFolder(
      _ identifier: ItemIdentifier, parent: ItemIdentifier, disambiguator: String,
      stem: (Builder) -> String
    ) {
      guard nodes[identifier] == nil else { return }
      let folderStem = stem(self)
      nodes[identifier] = Node(
        identifier: identifier, parent: parent, stem: folderStem, fileExtension: nil,
        disambiguator: disambiguator, kind: .folder, version: "")
    }

    private func key(_ id: UInt?) -> String {
      id.map { String($0) } ?? "none"
    }

    // The *Name functions return sanitized stems, each sanitized once.

    private func correspondentName(_ id: UInt?) -> String {
      guard let id else { return FileNaming.sanitize(labels.noCorrespondent) ?? "none" }
      return named(correspondentsByID[id]?.name, fallback: labels.unknownCorrespondent, id)
    }

    private func documentTypeName(_ id: UInt?) -> String {
      guard let id else { return FileNaming.sanitize(labels.noDocumentType) ?? "none" }
      return named(documentTypesByID[id]?.name, fallback: labels.unknownDocumentType, id)
    }

    private func tagName(_ id: UInt) -> String {
      named(tagsByID[id]?.name, fallback: labels.unknownTag, id)
    }

    /// The element's sanitized name, else the sanitized `"<fallback> <id>"`,
    /// else the id.
    private func named(_ name: String?, fallback: String, _ id: UInt) -> String {
      name.flatMap(FileNaming.sanitize) ?? FileNaming.sanitize("\(fallback) \(id)")
        ?? String(id)
    }

    /// Resolves names per folder and sorts each folder's children.
    func finish() -> ([ItemIdentifier: TreeItem], [ItemIdentifier: [ItemIdentifier]]) {
      var items: [ItemIdentifier: TreeItem] = [
        .root: TreeItem(identifier: .root, parent: .root, name: "", kind: .folder, version: "")
      ]
      var grouped: [ItemIdentifier: [Node]] = [:]
      for node in nodes.values {
        grouped[node.parent, default: []].append(node)
      }

      var childIDs: [ItemIdentifier: [ItemIdentifier]] = [:]
      for (parent, children) in grouped {
        // The names do not depend on the order of `children`.
        let names = FileNaming.resolveCollisions(
          children.map {
            FileNaming.Entry(
              stem: $0.stem, fileExtension: $0.fileExtension, disambiguator: $0.disambiguator,
              uniqueKey: $0.identifier.stringValue, keepsName: $0.keepsName)
          })
        var resolved: [TreeItem] = []
        for (node, name) in zip(children, names) {
          let item = TreeItem(
            identifier: node.identifier, parent: parent, name: name, kind: node.kind,
            version: node.version)
          items[node.identifier] = item
          resolved.append(item)
        }
        resolved.sort(by: LibraryTree.displayOrder)
        childIDs[parent] = resolved.map(\.identifier)
      }
      return (items, childIDs)
    }
  }

  /// Folders first, then documents; by name in Finder order; ties by
  /// identifier.
  static func displayOrder(_ lhs: TreeItem, _ rhs: TreeItem) -> Bool {
    if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
    switch lhs.name.localizedStandardCompare(rhs.name) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhs.identifier.stringValue < rhs.identifier.stringValue
    }
  }
}
