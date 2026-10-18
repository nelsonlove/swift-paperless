//
//  DomainReconcile.swift
//  FileProviderCore
//

import Foundation

/// Which File Provider domains to add, remove or rename so that there is one
/// domain per configured server, named after it.
///
/// Pure, so the app-side domain sync only applies the result. Identifiers are
/// strings: the domain identifier is the server's UUID string.
public enum DomainReconcile {
  public struct Domain: Equatable, Hashable, Sendable {
    public var identifier: String
    public var displayName: String

    public init(identifier: String, displayName: String) {
      self.identifier = identifier
      self.displayName = displayName
    }
  }

  public struct Result: Equatable, Sendable {
    /// Servers with no domain yet.
    public var add: [Domain]
    /// Domains whose server is gone.
    public var remove: [Domain]
    /// Domains whose server's display name changed. Apply each by calling
    /// `NSFileProviderManager.add` again with the same identifier and the new
    /// name, never by removing the domain: removal deletes its materialized
    /// files, Recents and bookmarks. That `add` with an existing identifier is
    /// idempotent and updates the display name is stated in upstream issue
    /// #727; it was not checked against Apple's documentation or a device.
    public var renameInPlace: [Domain]

    public var isEmpty: Bool { add.isEmpty && remove.isEmpty && renameInPlace.isEmpty }

    public init(add: [Domain] = [], remove: [Domain] = [], renameInPlace: [Domain] = []) {
      self.add = add
      self.remove = remove
      self.renameInPlace = renameInPlace
    }
  }

  /// - Parameters:
  ///   - servers: Server identifier to the display name its domain should have.
  ///   - domains: Existing domain identifier to its current display name.
  /// - Returns: Each list sorted by identifier. `remove` carries the existing
  ///   domain's name; `renameInPlace` carries the new name. A domain is only
  ///   in `remove` when its server is gone, never because of a rename.
  public static func reconcile(servers: [String: String], domains: [String: String]) -> Result {
    var result = Result()
    for (identifier, name) in servers {
      if let existing = domains[identifier] {
        if existing != name {
          result.renameInPlace.append(Domain(identifier: identifier, displayName: name))
        }
      } else {
        result.add.append(Domain(identifier: identifier, displayName: name))
      }
    }
    for (identifier, name) in domains where servers[identifier] == nil {
      result.remove.append(Domain(identifier: identifier, displayName: name))
    }
    result.add.sort { $0.identifier < $1.identifier }
    result.remove.sort { $0.identifier < $1.identifier }
    result.renameInPlace.sort { $0.identifier < $1.identifier }
    return result
  }
}
