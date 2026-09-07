import XCTest
@testable import Console

final class LLMRetryStatusTests: XCTestCase {

    // MARK: - H13-F01: digit substrings must not drive retry classification

    func testPermanent400WithDigitSubstringsIsNotRetried() async throws {
        var attempts = 0
        do {
            _ = try await RetryHelper.withRetry(maxAttempts: 3, initialDelay: 0.01) {
                attempts += 1
                throw LLMGeneratorError.apiError("[400] max_tokens must be less than 1500")
            }
        } catch {
            // expected throw
        }
        XCTAssertEqual(attempts, 1, "a real 4xx must fail on the first attempt")
    }

    func testNonBracketedProseIsNotRetriedOnDigits() async throws {
        var attempts = 0
        do {
            _ = try await RetryHelper.withRetry(maxAttempts: 3, initialDelay: 0.01) {
                attempts += 1
                throw LLMGeneratorError.apiError("Endpoint quota 1500 exceeded for model")
            }
        } catch { }
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - H13-F02: transient 529 / 504 must retry

    func testAnthropicOverloaded529IsRetried() async throws {
        var attempts = 0
        do {
            _ = try await RetryHelper.withRetry(maxAttempts: 3, initialDelay: 0.01) {
                attempts += 1
                throw LLMGeneratorError.apiError("[529] overloaded_error")
            }
        } catch { }
        XCTAssertEqual(attempts, 3, "529 overload should retry like 503")
    }

    func testGatewayTimeout504IsRetried() async throws {
        var attempts = 0
        do {
            _ = try await RetryHelper.withRetry(maxAttempts: 3, initialDelay: 0.01) {
                attempts += 1
                throw LLMGeneratorError.apiError("[504] gateway timeout")
            }
        } catch { }
        XCTAssertEqual(attempts, 3)
    }

    func testRealTransientStatusesStillRetry() async throws {
        for status in [429, 500, 502, 503] {
            var attempts = 0
            do {
                _ = try await RetryHelper.withRetry(maxAttempts: 3, initialDelay: 0.01) {
                    attempts += 1
                    throw LLMGeneratorError.apiError("[\(status)] body")
                }
            } catch { }
            XCTAssertEqual(attempts, 3, "[\(status)] should retry")
        }
    }

    func testPhraseFallbackStillAppliesWithoutBracket() async throws {
        var attempts = 0
        do {
            _ = try await RetryHelper.withRetry(maxAttempts: 2, initialDelay: 0.01) {
                attempts += 1
                throw LLMGeneratorError.apiError("Rate limit exceeded for this key")
            }
        } catch { }
        XCTAssertEqual(attempts, 2)
    }

    // MARK: - H13-F03: formatter must not mislabel via digit substrings

    func testFormatterMapsBracketedStatusNotBodyDigits() {
        let message = LLMErrorFormatter.userFriendlyMessage(
            for: LLMGeneratorError.apiError("[400] This model is limited to 500 requests per day")
        )
        XCTAssertFalse(
            message.contains("internal error"),
            "a 400 with '500' in the body must not read as an internal error: \(message)"
        )
        XCTAssertTrue(message.contains("API error"))
    }

    func testFormatterMapsRealStatuses() {
        let cases: [(Int, String)] = [
            (401, "Invalid API key"),
            (429, "Rate limit"),
            (500, "internal error"),
            (503, "temporarily unavailable"),
            (529, "overloaded"),
        ]
        for (status, expected) in cases {
            let message = LLMErrorFormatter.userFriendlyMessage(
                for: LLMGeneratorError.apiError("[\(status)] body")
            )
            XCTAssertTrue(message.contains(expected), "[\(status)] → \(message)")
        }
    }

    func testStatusParserOnlyAcceptsBracketPrefix() {
        XCTAssertNil(LLMAPIStatus.fromAPIMessage("quota is 1500 units"))
        XCTAssertNil(LLMAPIStatus.fromAPIMessage("error [429] mid-string"))
        XCTAssertNil(LLMAPIStatus.fromAPIMessage("[42] short"))
        XCTAssertEqual(LLMAPIStatus.fromAPIMessage("[429] Rate limit exceeded"), 429)
        XCTAssertEqual(LLMAPIStatus.fromAPIMessage("[529] overloaded_error"), 529)
        XCTAssertEqual(LLMAPIStatus.fromAPIMessage("[504] gateway timeout"), 504)
    }
}