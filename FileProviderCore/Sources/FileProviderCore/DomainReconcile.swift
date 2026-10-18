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

  /// A configured server, as the domain sync sees it.
  public struct Server: Equatable, Hashable, Sendable {
    /// The domain identifier: the server's UUID string.
    public var identifier: String
    /// The name the server is shown under (its friendly name or host).
    public var displayName: String
    /// The account's user name, used to tell apart servers that share a
    /// display name.
    public var userName: String?

    public init(identifier: String, displayName: String, userName: String? = nil) {
      self.identifier = identifier
      self.displayName = displayName
      self.userName = userName
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
  ///   - servers: The configured servers. Their domain names come from
  ///     ``displayNames(for:)``.
  ///   - domains: Existing domain identifier to its current display name.
  /// - Returns: Each list sorted by identifier. `remove` carries the existing
  ///   domain's name; `renameInPlace` carries the new name. A domain is only
  ///   in `remove` when its server is gone, never because of a rename.
  public static func reconcile(servers: [Server], domains: [String: String]) -> Result {
    reconcile(names: displayNames(for: servers), domains: domains)
  }

  /// The same, for servers given as identifier to display name, with no user
  /// names. Display names are still made distinct.
  public static func reconcile(servers: [String: String], domains: [String: String]) -> Result {
    reconcile(
      servers: servers.map { Server(identifier: $0.key, displayName: $0.value) },
      domains: domains)
  }

  /// The domain name for each server, distinct across servers (compared
  /// case-insensitively after NFC), so Files never lists two locations with
  /// one name. A name shared by several servers gets ` (<user name>)`, or
  /// ` (<first 8 characters of the identifier>)` when the server has no user
  /// name; names still shared after that get ` (<full identifier>)`.
  public static func displayNames(for servers: [Server]) -> [String: String] {
    func duplicates(_ names: [String: String]) -> Set<String> {
      let groups = Dictionary(grouping: names, by: { FileNaming.comparisonKey($0.value) })
      return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.key) })
    }

    var names = Dictionary(
      servers.map { ($0.identifier, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    let byID = Dictionary(
      servers.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

    for identifier in duplicates(names) {
      guard let server = byID[identifier] else { continue }
      if let user = server.userName, !user.isEmpty {
        names[identifier] = "\(server.displayName) (\(user))"
      } else {
        names[identifier] = "\(server.displayName) (\(identifier.prefix(8)))"
      }
    }
    for identifier in duplicates(names) {
      guard let server = byID[identifier] else { continue }
      names[identifier] = "\(server.displayName) (\(identifier))"
    }
    return names
  }

  private static func reconcile(names servers: [String: String], domains: [String: String])
    -> Result
  {
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
