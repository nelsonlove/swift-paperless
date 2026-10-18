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

  @Test("Servers without a domain are added; domains without a server are removed")
  func addAndRemove() {
    let result = DomainReconcile.reconcile(
      servers: ["b": "Home server", "a": "Office"],
      domains: ["a": "Office", "c": "Old server"])
    #expect(result.add == [Domain(identifier: "b", displayName: "Home server")])
    #expect(result.remove == [Domain(identifier: "c", displayName: "Old server")])
    #expect(result.renameInPlace.isEmpty)
  }

  @Test("A renamed server is renamed in place and never removed")
  func rename() {
    let result = DomainReconcile.reconcile(
      servers: ["a": "Office (new)", "b": "Home"], domains: ["a": "Office", "b": "Home"])
    #expect(
      result == .init(renameInPlace: [Domain(identifier: "a", displayName: "Office (new)")]))
    #expect(result.remove.isEmpty)
    #expect(result.add.isEmpty)
  }

  @Test("Matching state gives nothing to do")
  func noop() {
    #expect(DomainReconcile.reconcile(servers: ["a": "A"], domains: ["a": "A"]).isEmpty)
    #expect(DomainReconcile.reconcile(servers: [:], domains: [:]).isEmpty)
  }

  @Test("Results are sorted by identifier")
  func sorted() {
    let result = DomainReconcile.reconcile(
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
    #expect(names[first] == "Paperless (\(first))")
    #expect(names[second] == "Paperless (\(second))")
    #expect(names[third] == "Paperless (9F8E7D6C)")
    #expect(Set(names.values.map(FileNaming.comparisonKey)).count == 3)

    // The dictionary form has no user names and is made distinct too.
    let result = DomainReconcile.reconcile(
      servers: [first: "Home", third: "Home"], domains: [:])
    #expect(result.add.map(\.displayName) == ["Home (0A1B2C3D)", "Home (9F8E7D6C)"])
  }

  @Test("A second server with the same name renames the first in place")
  func newDuplicateRenamesInPlace() {
    let result = DomainReconcile.reconcile(
      servers: [
        Server(identifier: "a", displayName: "Paperless", userName: "office"),
        Server(identifier: "b", displayName: "Paperless", userName: "home"),
      ], domains: ["a": "Paperless"])
    #expect(result.add == [Domain(identifier: "b", displayName: "Paperless (home)")])
    #expect(result.renameInPlace == [Domain(identifier: "a", displayName: "Paperless (office)")])
    #expect(result.remove.isEmpty)
  }
}
