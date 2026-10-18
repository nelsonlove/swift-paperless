//
//  FolderLayout.swift
//  FileProviderCore
//

import Foundation

/// The shape of the canonical tree under a File Provider domain's root.
///
/// Every document appears exactly once in the canonical tree, so it has one
/// parent and the stable identity `doc:<id>`. The raw value is used both in
/// settings and inside folder identifiers (`dir:<layout>:<key>`), so it must
/// never change once shipped.
///
/// A `storagePath` case is planned; it needs the storage-path template renderer
/// and is added together with it.
public enum FolderLayout: String, CaseIterable, Codable, Hashable, Sendable {
  /// One folder per correspondent, plus "No correspondent".
  case correspondent
  /// One folder per document type, plus "No document type".
  case documentType
  /// One folder per year of the document's `created` date.
  case year
  /// One folder per correspondent, each holding one folder per year.
  case correspondentYear
  /// Every document directly in the root.
  case flat
}
