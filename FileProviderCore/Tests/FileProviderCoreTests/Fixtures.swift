//
//  Fixtures.swift
//  FileProviderCore
//

import Common
import DataModel
import Foundation
import SwiftUI

@testable import FileProviderCore

/// A small made-up library. No real people or documents.
enum Fixtures {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  static func date(_ year: Int, _ month: Int = 1, _ day: Int = 15) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  static func correspondent(_ id: UInt, _ name: String) -> Correspondent {
    Correspondent(
      id: id, name: name, slug: name.lowercased(), matchingAlgorithm: .auto, match: "",
      isInsensitive: true)
  }

  static func documentType(_ id: UInt, _ name: String) -> DocumentType {
    DocumentType(
      id: id, name: name, slug: name.lowercased(), match: "", matchingAlgorithm: .auto,
      isInsensitive: true)
  }

  static func tag(_ id: UInt, _ name: String, parent: UInt? = nil) -> Tag {
    Tag(
      id: id, isInboxTag: false, name: name, slug: name.lowercased(), color: HexColor(Color.gray),
      match: "", matchingAlgorithm: .auto, isInsensitive: true, parent: parent)
  }

  static func document(
    _ id: UInt, _ title: String, correspondent: UInt? = nil, type: UInt? = nil,
    tags: [UInt] = [], year: Int = 2026, modified: Date? = nil,
    originalFileName: String? = nil
  ) -> Document {
    Document(
      id: id, title: title, documentType: type, correspondent: correspondent,
      created: date(year), tags: tags, modified: modified ?? date(year, 2, 1),
      originalFileName: originalFileName)
  }

  static let correspondents = [
    correspondent(1, "Acme Utilities"),
    correspondent(2, "Northwind Bank"),
    correspondent(3, "City Library"),
  ]

  static let documentTypes = [
    documentType(1, "Invoice"),
    documentType(2, "Letter"),
    documentType(3, "Statement"),
  ]

  // "insurance" is a child of "home".
  static let tags = [
    tag(1, "inbox"),
    tag(2, "tax"),
    tag(3, "home"),
    tag(4, "insurance", parent: 3),
  ]

  static let documents = [
    document(10, "Electricity bill March 2026", correspondent: 1, type: 1, tags: [1, 3]),
    document(11, "Account statement Q1", correspondent: 2, type: 3, tags: [2], year: 2025),
    document(12, "Membership renewal", correspondent: 3, type: 2, tags: []),
    document(13, "Unsorted scan", tags: [4]),
    document(14, "Water bill", correspondent: 1, type: 1, tags: [4, 2], year: 2025),
  ]

  static func tree(
    _ settings: FileProviderSettings = .default, documents: [Document] = documents,
    tags: [Tag] = tags
  ) -> LibraryTree {
    LibraryTree(
      documents: documents, tags: tags, correspondents: correspondents,
      documentTypes: documentTypes, settings: settings, calendar: calendar)
  }
}

extension LibraryTree {
  /// Child names of a container, in enumeration order.
  func names(_ identifier: ItemIdentifier) -> [String] {
    children(of: identifier)?.map(\.name) ?? []
  }
}
