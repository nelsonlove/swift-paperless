//
//  FetchFailureAnswerTests.swift
//  FileProviderCore
//

import Testing

@testable import FileProviderCore

@Suite
struct FetchFailureAnswerTests {
  /// Each failure as the extension classifies it.
  enum Case: CaseIterable, Sendable {
    case serverNotFoundStillInDatabase
    case proxyNotFound
    case notFoundRowMissing
    case forbidden
    case connectivity

    var failure: FetchFailureAnswer.Failure {
      switch self {
      case .serverNotFoundStillInDatabase, .proxyNotFound, .notFoundRowMissing: .notFound
      case .forbidden, .connectivity: .other
      }
    }
  }

  @Test("A stored copy is served for any failure", arguments: Case.allCases)
  func storedCopy(_ failure: Case) {
    #expect(
      FetchFailureAnswer.answer(for: failure.failure, hasStoredCopy: true, isCancelled: false)
        == .storedCopy)
  }

  @Test(
    "Without a stored copy a 404 is serverUnreachable, from any source",
    arguments: [Case.serverNotFoundStillInDatabase, .proxyNotFound, .notFoundRowMissing])
  func notFound(_ failure: Case) {
    #expect(
      FetchFailureAnswer.answer(for: failure.failure, hasStoredCopy: false, isCancelled: false)
        == .serverUnreachable)
  }

  @Test(
    "Without a stored copy a 403 or a connectivity error is its own error",
    arguments: [Case.forbidden, .connectivity])
  func otherErrors(_ failure: Case) {
    #expect(
      FetchFailureAnswer.answer(for: failure.failure, hasStoredCopy: false, isCancelled: false)
        == .error)
  }

  @Test("A cancellation is a cancellation", arguments: Case.allCases, [true, false])
  func cancelled(_ failure: Case, hasStoredCopy: Bool) {
    #expect(
      FetchFailureAnswer.answer(
        for: failure.failure, hasStoredCopy: hasStoredCopy, isCancelled: true) == .cancelled)
  }
}

@Suite
struct ErrorAnswerTests {
  @Test("A 404 maps to serverUnreachable, never noSuchItem")
  func notFound() {
    #expect(ErrorAnswer.answer(for: .notFound) == .serverUnreachable)
  }

  @Test("Each kind maps to the error the header names for it")
  func kinds() {
    #expect(ErrorAnswer.answer(for: .libraryUnavailable) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .unreachable) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .unauthorized) == .notAuthenticated)
    #expect(ErrorAnswer.answer(for: .forbidden) == .noPermission)
    #expect(ErrorAnswer.answer(for: .cancelled) == .cancelled)
    #expect(ErrorAnswer.answer(for: .other) == .unrepresentable)
  }
}
