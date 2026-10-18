//
//  FetchFailureAnswerTests.swift
//  FileProviderCore
//

import Foundation
import Testing

@testable import FileProviderCore

@Suite
struct FetchFailureAnswerTests {
  static let copy = URL(fileURLWithPath: "/tmp/stored-copy.pdf")
  static let steps: [FetchFailureAnswer.Step] = [.serverRow, .repository, .download]
  static let keepingCopy: [ErrorAnswer.Kind] = [
    .notFound, .unauthorized, .unreachable, .libraryUnavailable, .other,
  ]

  @Test(
    "A stored copy is served for a 404, 401, unreachable or other failure, at any step",
    arguments: keepingCopy, steps)
  func storedCopy(_ kind: ErrorAnswer.Kind, _ step: FetchFailureAnswer.Step) {
    #expect(
      FetchFailureAnswer.answer(for: kind, in: step, storedCopy: Self.copy)
        == .storedCopy(Self.copy))
    #expect(FetchFailureAnswer.answer(for: kind, in: step, storedCopy: nil) == .mapError)
  }

  @Test("A 403 from the download is no permission, even with a stored copy")
  func forbiddenDownload() {
    #expect(
      FetchFailureAnswer.answer(for: .forbidden, in: .download, storedCopy: Self.copy)
        == .noPermission)
    #expect(
      FetchFailureAnswer.answer(for: .forbidden, in: .download, storedCopy: nil) == .noPermission)
  }

  @Test("A 403 from building the repository serves the stored copy")
  func forbiddenRepository() {
    #expect(
      FetchFailureAnswer.answer(for: .forbidden, in: .repository, storedCopy: Self.copy)
        == .storedCopy(Self.copy))
    #expect(
      FetchFailureAnswer.answer(for: .forbidden, in: .repository, storedCopy: nil) == .mapError)
  }

  @Test("A cancellation is a cancellation", arguments: steps)
  func cancelled(_ step: FetchFailureAnswer.Step) {
    #expect(
      FetchFailureAnswer.answer(for: .cancelled, in: step, storedCopy: Self.copy) == .cancelled)
  }
}

@Suite
struct ErrorAnswerTests {
  @Test("In a fetch, no kind answers noSuchItem")
  func fetchNeverDeletes() {
    #expect(ErrorAnswer.answer(for: .notFound, inFetch: true) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .documentNotInLibrary, inFetch: true) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .noSuchItem, inFetch: true) == .serverUnreachable)
  }

  @Test("Other callers' noSuchItem passes through")
  func otherCallers() {
    #expect(ErrorAnswer.answer(for: .noSuchItem, inFetch: false) == .passThrough)
    #expect(ErrorAnswer.answer(for: .notFound, inFetch: false) == .serverUnreachable)
  }

  @Test("Each kind maps to the error the header names for it", arguments: [true, false])
  func kinds(_ inFetch: Bool) {
    #expect(ErrorAnswer.answer(for: .libraryUnavailable, inFetch: inFetch) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .unreachable, inFetch: inFetch) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .unauthorized, inFetch: inFetch) == .notAuthenticated)
    #expect(ErrorAnswer.answer(for: .forbidden, inFetch: inFetch) == .noPermission)
    #expect(ErrorAnswer.answer(for: .cancelled, inFetch: inFetch) == .cancelled)
    #expect(ErrorAnswer.answer(for: .systemError, inFetch: inFetch) == .passThrough)
    #expect(ErrorAnswer.answer(for: .other, inFetch: inFetch) == .unrepresentable)
  }

  @Test("HTTP statuses classify as the download reports them")
  func statuses() {
    #expect(ErrorAnswer.Kind(httpStatus: 401) == .unauthorized)
    #expect(ErrorAnswer.Kind(httpStatus: 403) == .forbidden)
    #expect(ErrorAnswer.Kind(httpStatus: 404) == .notFound)
    #expect(ErrorAnswer.Kind(httpStatus: 500) == .other)
    #expect(ErrorAnswer.Kind(httpStatus: 304) == .other)
  }
}
