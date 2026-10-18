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
    #expect(result.readd.isEmpty)
  }

  @Test("A renamed server is re-added with its new name")
  func rename() {
    let result = DomainReconcile.reconcile(
      servers: ["a": "Office (new)"], domains: ["a": "Office"])
    #expect(result == .init(readd: [Domain(identifier: "a", displayName: "Office (new)")]))
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
}
