//
//  FetchFailureAnswerTests.swift
//  FileProviderCore
//

import Common
import Foundation
import Networking
import Testing

@testable import FileProviderCore

@Suite
struct FetchFailureAnswerTests {
  typealias Answer = FetchFailureAnswer<String>

  static let keepingCopy: [ErrorAnswer.Kind] = [
    .notFound, .unauthorized, .unreachable, .libraryUnavailable, .other,
  ]

  @Test("A stored copy is served for a 404, 401, unreachable or other failure", arguments: keepingCopy)
  func storedCopy(_ kind: ErrorAnswer.Kind) {
    #expect(Answer.answer(for: kind, storedCopy: "copy") == .storedCopy("copy"))
  }

  @Test("Without a stored copy the error is rethrown for the map", arguments: keepingCopy)
  func rethrow(_ kind: ErrorAnswer.Kind) {
    #expect(Answer.answer(for: kind, storedCopy: nil) == .rethrow)
  }

  @Test("A 403 is no permission, even with a stored copy", arguments: ["copy", nil] as [String?])
  func forbidden(_ storedCopy: String?) {
    #expect(Answer.answer(for: .forbidden, storedCopy: storedCopy) == .noPermission)
  }

  @Test("A cancellation is a cancellation", arguments: ["copy", nil] as [String?])
  func cancelled(_ storedCopy: String?) {
    #expect(Answer.answer(for: .cancelled, storedCopy: storedCopy) == .cancelled)
  }

  @Test("A 404 without a stored copy ends as serverUnreachable, never noSuchItem")
  func notFoundEnds() {
    #expect(Answer.answer(for: .notFound, storedCopy: nil) == .rethrow)
    #expect(ErrorAnswer.answer(for: .notFound) == .serverUnreachable)
  }
}

@Suite
struct ErrorAnswerTests {
  @Test("Each kind maps to the error the header names for it")
  func kinds() {
    #expect(ErrorAnswer.answer(for: .notFound) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .libraryUnavailable) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .unreachable) == .serverUnreachable)
    #expect(ErrorAnswer.answer(for: .unauthorized) == .notAuthenticated)
    #expect(ErrorAnswer.answer(for: .forbidden) == .noPermission)
    #expect(ErrorAnswer.answer(for: .cancelled) == .cancelled)
    #expect(ErrorAnswer.answer(for: .other) == .unrepresentable)
  }

  @Test("A 404 status, as the download reports it, is notFound")
  func notFound() {
    // ApiRepository.validateDownloadResponse throws this for a 404.
    let error = RequestError.unexpectedStatusCode(code: .notFound, detail: "")
    #expect(ErrorAnswer.Kind(classifying: error) == .notFound)
  }

  @Test("A 403 is forbidden")
  func forbidden() {
    #expect(ErrorAnswer.Kind(classifying: RequestError.forbidden(detail: nil)) == .forbidden)
  }

  @Test("A 401 is unauthorized")
  func unauthorized() {
    #expect(ErrorAnswer.Kind(classifying: RequestError.unauthorized(detail: "")) == .unauthorized)
  }

  @Test("A transport failure, normalized as the download does it, is unreachable")
  func connectivity() {
    for code in [URLError.Code.timedOut, .cannotConnectToHost, .notConnectedToInternet] {
      let error = RequestError.normalizingTransportFailure(
        URLError(code), path: .satisfied)
      #expect(ErrorAnswer.Kind(classifying: error) == .unreachable)
    }
  }

  @Test("A 5xx is other: a transient error, or the stored copy")
  func serverError() {
    let error = RequestError.unexpectedStatusCode(code: .internalServerError, detail: nil)
    #expect(ErrorAnswer.Kind(classifying: error) == .other)
    #expect(FetchFailureAnswer.answer(for: .other, storedCopy: "copy") == .storedCopy("copy"))
  }

  @Test("A cancellation is cancelled")
  func cancelled() {
    #expect(ErrorAnswer.Kind(classifying: CancellationError()) == .cancelled)
  }
}
