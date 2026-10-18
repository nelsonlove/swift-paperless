//
//  DomainReconcile.swift
//  FileProviderCore
//

import Foundation

/// Which File Provider domains to add, remove or re-add so that there is one
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
    /// Domains whose server's display name changed: remove the old domain and
    /// add this one (a domain's display name cannot be changed in place).
    public var readd: [Domain]

    public var isEmpty: Bool { add.isEmpty && remove.isEmpty && readd.isEmpty }

    public init(add: [Domain] = [], remove: [Domain] = [], readd: [Domain] = []) {
      self.add = add
      self.remove = remove
      self.readd = readd
    }
  }

  /// - Parameters:
  ///   - servers: Server identifier to the display name its domain should have.
  ///   - domains: Existing domain identifier to its current display name.
  /// - Returns: Each list sorted by identifier. `remove` carries the existing
  ///   domain's name; `readd` carries the new name.
  public static func reconcile(servers: [String: String], domains: [String: String]) -> Result {
    var result = Result()
    for (identifier, name) in servers {
      if let existing = domains[identifier] {
        if existing != name {
          result.readd.append(Domain(identifier: identifier, displayName: name))
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
    result.readd.sort { $0.identifier < $1.identifier }
    return result
  }
}
