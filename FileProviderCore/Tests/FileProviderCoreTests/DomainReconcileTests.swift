//
//  DomainReconcileTests.swift
//  FileProviderCore
//

import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct DomainReconcileTests {
  typealias Domain = DomainReconcile.Domain

  /// Servers given as identifier to display name, with no user names.
  private func reconcile(servers: [String: String], domains: [String: String])
    -> DomainReconcile.Result
  {
    DomainReconcile.reconcile(
      servers: servers.map { DomainReconcile.Server(identifier: $0.key, displayName: $0.value) },
      domains: domains)
  }

  @Test("Servers without a domain are added; domains without a server are removed")
  func addAndRemove() {
    let result = reconcile(
      servers: ["b": "Home server", "a": "Office"],
      domains: ["a": "Office", "c": "Old server"])
    #expect(result.add == [Domain(identifier: "b", displayName: "Home server")])
    #expect(result.remove == [Domain(identifier: "c", displayName: "Old server")])
    #expect(result.renameInPlace.isEmpty)
  }

  @Test("A renamed server is renamed in place and never removed")
  func rename() {
    let result = reconcile(
      servers: ["a": "Office (new)", "b": "Home"], domains: ["a": "Office", "b": "Home"])
    #expect(
      result == .init(renameInPlace: [Domain(identifier: "a", displayName: "Office (new)")]))
    #expect(result.remove.isEmpty)
    #expect(result.add.isEmpty)
  }

  @Test("Matching state gives nothing to do")
  func noop() {
    #expect(reconcile(servers: ["a": "A"], domains: ["a": "A"]).isEmpty)
    #expect(reconcile(servers: [:], domains: [:]).isEmpty)
  }

  @Test("Results are sorted by identifier")
  func sorted() {
    let result = reconcile(
      servers: ["c": "C", "a": "A", "b": "B"], domains: ["z": "Z", "y": "Y"])
    #expect(result.add.map(\.identifier) == ["a", "b", "c"])
    #expect(result.remove.map(\.identifier) == ["y", "z"])
  }

  typealias Server = DomainReconcile.Server

  @Test("Servers sharing a display name get the user name")
  func sharedNameWithUsers() {
    let result = DomainReconcile.reconcile(
      servers: [
        Server(identifier: "a1", displayName: "Paperless", userName: "office"),
        Server(identifier: "b2", displayName: "paperless", userName: "home"),
        Server(identifier: "c3", displayName: "Archive", userName: "office"),
      ], domains: [:])
    #expect(
      result.add == [
        Domain(identifier: "a1", displayName: "Paperless (office)"),
        Domain(identifier: "b2", displayName: "paperless (home)"),
        Domain(identifier: "c3", displayName: "Archive"),
      ])
  }

  @Test("Without user names, or with the same user, ids tell servers apart")
  func sharedNameWithoutUsers() {
    let first = "0A1B2C3D-0000-0000-0000-000000000001"
    let second = "0A1B2C3D-0000-0000-0000-000000000002"
    let third = "9F8E7D6C-0000-0000-0000-000000000003"
    let names = DomainReconcile.displayNames(for: [
      Server(identifier: first, displayName: "Paperless", userName: "office"),
      Server(identifier: second, displayName: "Paperless", userName: "office"),
      Server(identifier: third, displayName: "Paperless"),
    ])
    #expect(names[first] == "Paperless (office)")
    #expect(names[second] == "Paperless (0A1B2C3D)")
    #expect(names[third] == "Paperless (9F8E7D6C)")
    #expect(Set(names.values.map(FileNaming.comparisonKey)).count == 3)

    // Without user names the 8-character id tells them apart.
    let result = reconcile(servers: [first: "Home", third: "Home"], domains: [:])
    #expect(result.add.map(\.displayName) == ["Home (0A1B2C3D)", "Home (9F8E7D6C)"])
  }

  @Test("Names stay distinct when a server is literally named like a generated name")
  func craftedNames() {
    let first = "0A1B2C3D-0000-0000-0000-000000000001"
    let second = "0A1B2C3D-0000-0000-0000-000000000002"
    let crafted = "00000000-0000-0000-0000-000000000000"
    let servers = [
      Server(identifier: first, displayName: "Home"),
      Server(identifier: second, displayName: "Home"),
      Server(identifier: crafted, displayName: "Home (\(second))"),
      Server(identifier: "11111111-0000-0000-0000-000000000000", displayName: "home (0a1b2c3d)"),
    ]
    let names = DomainReconcile.displayNames(for: servers)
    #expect(names.count == 4)
    #expect(Set(names.values.map(FileNaming.comparisonKey)).count == 4)
    #expect(names[crafted] == "Home (\(second))")
    #expect(names[second] == "Home (\(second) 2)")
  }

  @Test("Adding a server with a shared name never renames the existing domain")
  func addDoesNotRename() {
    let result = DomainReconcile.reconcile(
      servers: [
        Server(identifier: "a", displayName: "Paperless", userName: "office"),
        Server(identifier: "b", displayName: "Paperless", userName: "home"),
      ], domains: ["a": "Paperless"])
    #expect(result.add == [Domain(identifier: "b", displayName: "Paperless (home)")])
    #expect(result.renameInPlace.isEmpty)
    #expect(result.remove.isEmpty)
  }

  @Test("Removing the other server does not rename the remaining one back")
  func removeDoesNotRenameBack() {
    let result = DomainReconcile.reconcile(
      servers: [Server(identifier: "b", displayName: "Paperless", userName: "home")],
      domains: ["a": "Paperless", "b": "Paperless (home)"])
    #expect(result.remove == [Domain(identifier: "a", displayName: "Paperless")])
    #expect(result.renameInPlace.isEmpty)
    #expect(result.add.isEmpty)
  }

  @Test("A server's own name change still renames its domain in place, either way")
  func ownRename() {
    let longer = DomainReconcile.reconcile(
      servers: [Server(identifier: "a", displayName: "Office (new)")], domains: ["a": "Office"])
    #expect(longer.renameInPlace == [Domain(identifier: "a", displayName: "Office (new)")])
    let other = DomainReconcile.reconcile(
      servers: [Server(identifier: "a", displayName: "Archive")], domains: ["a": "Office"])
    #expect(other.renameInPlace == [Domain(identifier: "a", displayName: "Archive")])
    // Known limit, documented: a change that only drops a trailing
    // parenthesized part looks like a derived name and keeps the domain name.
    let shorter = DomainReconcile.reconcile(
      servers: [Server(identifier: "a", displayName: "Office")], domains: ["a": "Office (new)"])
    #expect(shorter.isEmpty)
  }

  @Test("A change of user name alone keeps the domain name")
  func userNameChange() {
    let result = DomainReconcile.reconcile(
      servers: [
        Server(identifier: "a", displayName: "Paperless", userName: "bob"),
        Server(identifier: "b", displayName: "Paperless", userName: "carol"),
      ], domains: ["a": "Paperless (alice)", "b": "Paperless (carol)"])
    #expect(result.isEmpty)
  }

  @Test("Of two existing domains with one name, the smaller server id keeps it")
  func existingClash() {
    let same = DomainReconcile.reconcile(
      servers: [
        Server(identifier: "b", displayName: "Paperless", userName: "home"),
        Server(identifier: "a", displayName: "Paperless", userName: "office"),
      ], domains: ["a": "Paperless", "b": "Paperless"])
    #expect(same.renameInPlace == [Domain(identifier: "b", displayName: "Paperless (home)")])
    #expect(same.add.isEmpty && same.remove.isEmpty)

    let caseOnly = DomainReconcile.reconcile(
      servers: [
        Server(identifier: "a", displayName: "Paperless", userName: "office"),
        Server(identifier: "b", displayName: "paperless", userName: "home"),
      ], domains: ["a": "Paperless", "b": "paperless"])
    #expect(caseOnly.renameInPlace == [Domain(identifier: "b", displayName: "paperless (home)")])

    // Without user names the loser takes its id.
    let names = DomainReconcile.displayNames(
      for: [
        Server(identifier: "0A1B2C3D-1", displayName: "Paperless"),
        Server(identifier: "9F8E7D6C-2", displayName: "Paperless"),
      ], existing: ["0A1B2C3D-1": "Paperless", "9F8E7D6C-2": "Paperless"])
    #expect(names == ["0A1B2C3D-1": "Paperless", "9F8E7D6C-2": "Paperless (9F8E7D6C)"])
  }
}
