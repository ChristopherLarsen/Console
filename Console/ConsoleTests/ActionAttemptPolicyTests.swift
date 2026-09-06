import XCTest
@testable import Console

final class ActionAttemptPolicyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 15
    }

    // MARK: - Retry default is off

    func testRetryOffIgnoresStoredMaxRetries() {
        let policy = ActionAttemptPolicy(retryOnFailure: false, maxRetries: 99, hasFallback: false)
        XCTAssertFalse(policy.retryEnabled)
        XCTAssertEqual(policy.primaryAttemptCount, 1)
    }

    func testRetryOffIsTheCommandActionDefault() {
        let action = CommandAction(type: .appleScript, payload: "return \"ok\"")
        XCTAssertFalse(action.retryOnFailure)
        XCTAssertNil(action.maxRetries)
        let policy = ActionAttemptPolicy(action: action)
        XCTAssertEqual(policy.primaryAttemptCount, 1)
        XCTAssertFalse(policy.hasFallback)
    }

    // MARK: - Documented maxRetries normalization

    func testNilMaxRetriesDefaultsToThreeWhenRetryEnabled() {
        let policy = ActionAttemptPolicy(retryOnFailure: true, maxRetries: nil, hasFallback: false)
        XCTAssertEqual(policy.primaryAttemptCount, ActionAttemptPolicy.defaultPrimaryAttempts)
        XCTAssertEqual(ActionAttemptPolicy.normalize(nil), 3)
    }

    func testZeroMaxRetriesNormalizesToOne() {
        XCTAssertEqual(ActionAttemptPolicy.normalize(0), 1)
        let policy = ActionAttemptPolicy(retryOnFailure: true, maxRetries: 0, hasFallback: false)
        XCTAssertEqual(policy.primaryAttemptCount, 1)
    }

    func testNegativeMaxRetriesNormalizesToOne() {
        XCTAssertEqual(ActionAttemptPolicy.normalize(-3), 1)
        let policy = ActionAttemptPolicy(retryOnFailure: true, maxRetries: -3, hasFallback: false)
        XCTAssertEqual(policy.primaryAttemptCount, 1)
    }

    func testInRangeMaxRetriesIsHonoredAsTotalPrimaryAttempts() {
        let policy = ActionAttemptPolicy(retryOnFailure: true, maxRetries: 3, hasFallback: false)
        XCTAssertEqual(policy.primaryAttemptCount, 3)
    }

    func testOverCapMaxRetriesClampsToTen() {
        XCTAssertEqual(ActionAttemptPolicy.normalize(11), 10)
        XCTAssertEqual(ActionAttemptPolicy.normalize(100), 10)
        let policy = ActionAttemptPolicy(retryOnFailure: true, maxRetries: 11, hasFallback: false)
        XCTAssertEqual(policy.primaryAttemptCount, ActionAttemptPolicy.maxPrimaryAttempts)
    }

    func testSaveRejectsNegativeAndOverCapButAllowsZeroAndNil() {
        XCTAssertNil(ActionAttemptPolicy.retryLimitValidationMessage(retryOnFailure: false, maxRetries: -1))
        XCTAssertNil(ActionAttemptPolicy.retryLimitValidationMessage(retryOnFailure: true, maxRetries: nil))
        XCTAssertNil(ActionAttemptPolicy.retryLimitValidationMessage(retryOnFailure: true, maxRetries: 0))
        XCTAssertNil(ActionAttemptPolicy.retryLimitValidationMessage(retryOnFailure: true, maxRetries: 3))
        XCTAssertNotNil(ActionAttemptPolicy.retryLimitValidationMessage(retryOnFailure: true, maxRetries: -1))
        XCTAssertNotNil(ActionAttemptPolicy.retryLimitValidationMessage(retryOnFailure: true, maxRetries: 11))
    }

    // MARK: - Fallback eligibility

    func testFallbackRunsOnlyAfterExhaustion() {
        let policy = ActionAttemptPolicy(retryOnFailure: true, maxRetries: 2, hasFallback: true)
        XCTAssertTrue(policy.shouldRunFallback(primarySucceeded: false, isCancelled: false))
        XCTAssertFalse(policy.shouldRunFallback(primarySucceeded: true, isCancelled: false))
    }

    func testFallbackNeverRunsAfterCancellation() {
        let policy = ActionAttemptPolicy(retryOnFailure: true, maxRetries: 3, hasFallback: true)
        XCTAssertFalse(policy.shouldRunFallback(primarySucceeded: false, isCancelled: true))
    }

    func testNoFallbackWhenAbsent() {
        let policy = ActionAttemptPolicy(retryOnFailure: true, maxRetries: 2, hasFallback: false)
        XCTAssertFalse(policy.shouldRunFallback(primarySucceeded: false, isCancelled: false))
    }

    // MARK: - Validator covers fallbacks and retry limits

    func testValidatorRejectsEmptyFallbackPayload() {
        let command = Command(
            name: "Synthetic Invalid Fallback",
            triggerPhrases: ["synthetic policy fallback"],
            actions: [
                CommandAction(
                    type: .appleScript,
                    payload: "return \"ok\"",
                    fallbackAction: FallbackAction(type: .appleScript, payload: "   ")
                )
            ],
            executionMode: .appleScript
        )
        let result = CommandValidator().validateCommand(command)
        guard case .failure(let message) = result else {
            XCTFail("Expected fallback validation failure, got \(result)")
            return
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("fallback"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("empty"), message)
    }

    func testValidatorRejectsOutOfRangeMaxRetries() {
        let command = Command(
            name: "Synthetic Overcap Retries",
            triggerPhrases: ["synthetic policy retries"],
            actions: [
                CommandAction(
                    type: .appleScript,
                    payload: "return \"ok\"",
                    retryOnFailure: true,
                    maxRetries: 11
                )
            ],
            executionMode: .appleScript
        )
        let result = CommandValidator().validateCommand(command)
        guard case .failure(let message) = result else {
            XCTFail("Expected maxRetries validation failure, got \(result)")
            return
        }
        XCTAssertTrue(message.contains("maxRetries"), message)
    }

    func testValidatorAcceptsZeroMaxRetriesWhenRetryEnabled() {
        let command = Command(
            name: "Synthetic Zero Retries",
            triggerPhrases: ["synthetic policy zero"],
            actions: [
                CommandAction(
                    type: .appleScript,
                    payload: "return \"ok\"",
                    delayAfterMS: 0,
                    retryOnFailure: true,
                    maxRetries: 0
                )
            ],
            executionMode: .appleScript
        )
        let result = CommandValidator().validateCommand(command)
        XCTAssertTrue(result.isSuccess, "Zero maxRetries should be saved and normalized at runtime, got \(result)")
    }

    func testValidatorFlagsDangerousFallbackPayload() {
        let command = Command(
            name: "Synthetic Dangerous Fallback",
            triggerPhrases: ["synthetic policy danger"],
            actions: [
                CommandAction(
                    type: .appleScript,
                    payload: "return \"ok\"",
                    fallbackAction: FallbackAction(
                        type: .appleScript,
                        payload: """
                        -- synthetic fixture: rm -rf
                        return "fallback"
                        """
                    )
                )
            ],
            executionMode: .appleScript
        )
        let result = CommandValidator().validateCommand(command)
        guard case .requiresConfirmation = result else {
            XCTFail("Expected confirmation for dangerous fallback, got \(result)")
            return
        }
    }
}
