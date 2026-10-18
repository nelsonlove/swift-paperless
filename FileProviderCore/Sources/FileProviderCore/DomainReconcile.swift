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
  ///     ``displayNames(for:existing:)``.
  ///   - domains: Existing domain identifier to its current display name.
  /// - Returns: Each list sorted by identifier. `remove` carries the existing
  ///   domain's name; `renameInPlace` carries the new name. A domain is only
  ///   in `remove` when its server is gone, and only in `renameInPlace` when
  ///   its own server's display name changed: adding or removing another
  ///   server never renames an existing domain.
  public static func reconcile(servers: [Server], domains: [String: String]) -> Result {
    let names = displayNames(for: servers, existing: domains)
    var result = Result()
    for (identifier, name) in names {
      if let existing = domains[identifier] {
        if existing != name {
          result.renameInPlace.append(Domain(identifier: identifier, displayName: name))
        }
      } else {
        result.add.append(Domain(identifier: identifier, displayName: name))
      }
    }
    for (identifier, name) in domains where names[identifier] == nil {
      result.remove.append(Domain(identifier: identifier, displayName: name))
    }
    result.add.sort { $0.identifier < $1.identifier }
    result.remove.sort { $0.identifier < $1.identifier }
    result.renameInPlace.sort { $0.identifier < $1.identifier }
    return result
  }

  /// The domain name for each server, always distinct across servers
  /// (compared case-insensitively after NFC), so Files never lists two
  /// locations with one name.
  ///
  /// A server whose existing domain name is its display name, or one this
  /// function derives from it, keeps that name, so adding or removing another
  /// server never renames it. Every other server (a new one, or one whose
  /// display name changed) is named in identifier order with the first free
  /// name of: its display name, when no other server shares that display
  /// name; ` (<user name>)` appended; ` (<first 8 characters of the
  /// identifier>)` appended; ` (<identifier>)` appended; then
  /// ` (<identifier> <n>)` for n = 2, 3, and so on. The counter makes every
  /// candidate different, so a free name is always found.
  public static func displayNames(for servers: [Server], existing: [String: String] = [:])
    -> [String: String]
  {
    let unique = Dictionary(
      servers.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first }
    ).values.sorted { $0.identifier < $1.identifier }
    let sharedDisplayNames = Set(
      Dictionary(grouping: unique, by: { FileNaming.comparisonKey($0.displayName) })
        .filter { $0.value.count > 1 }.keys)

    var names: [String: String] = [:]
    var claimed = Set<String>()
    var pending: [Server] = []
    for server in unique {
      if let current = existing[server.identifier], isDerived(current, from: server) {
        names[server.identifier] = current
        claimed.insert(FileNaming.comparisonKey(current))
      } else {
        pending.append(server)
      }
    }

    for server in pending {
      let base = server.displayName
      var candidates: [String] = []
      if !sharedDisplayNames.contains(FileNaming.comparisonKey(base)) {
        candidates.append(base)
      }
      if let user = server.userName, !user.isEmpty {
        candidates.append("\(base) (\(user))")
      }
      candidates.append("\(base) (\(server.identifier.prefix(8)))")
      candidates.append("\(base) (\(server.identifier))")

      var name = candidates.first { !claimed.contains(FileNaming.comparisonKey($0)) }
      var counter = 2
      while name == nil {
        let candidate = "\(base) (\(server.identifier) \(counter))"
        if !claimed.contains(FileNaming.comparisonKey(candidate)) { name = candidate }
        counter += 1
      }
      names[server.identifier] = name!
      claimed.insert(FileNaming.comparisonKey(name!))
    }
    return names
  }

  /// Whether `name` is the server's display name or one of the names
  /// ``displayNames(for:existing:)`` derives from it.
  static func isDerived(_ name: String, from server: Server) -> Bool {
    let base = server.displayName
    if name == base { return true }
    let prefix = "\(base) ("
    guard name.hasPrefix(prefix), name.hasSuffix(")") else { return false }
    let inner = name.dropFirst(prefix.count).dropLast()
    if let user = server.userName, !user.isEmpty, inner == user { return true }
    let identifier = server.identifier
    if inner == identifier.prefix(8) || inner == identifier { return true }
    let counterPrefix = "\(identifier) "
    guard inner.hasPrefix(counterPrefix) else { return false }
    let counter = inner.dropFirst(counterPrefix.count)
    return !counter.isEmpty && counter.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
