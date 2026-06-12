import XCTest
@testable import AirKit

final class BackoffTests: XCTestCase {
    func testDelayGrowsExponentiallyWithoutJitter() {
        let policy = BackoffPolicy(maxAttempts: 5, baseDelay: 1, multiplier: 2, maxDelay: 100)
        XCTAssertEqual(policy.delay(forAttempt: 1, jitterFraction: 0), 1, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 2, jitterFraction: 0), 2, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 3, jitterFraction: 0), 4, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 4, jitterFraction: 0), 8, accuracy: 0.001)
    }

    func testDelayIsCapped() {
        let policy = BackoffPolicy(maxAttempts: 10, baseDelay: 1, multiplier: 2, maxDelay: 5)
        XCTAssertEqual(policy.delay(forAttempt: 8, jitterFraction: 0), 5, accuracy: 0.001)
    }

    func testRetryableClassification() {
        XCTAssertTrue(RetryableError.serverError(status: 500).isRetryable)
        XCTAssertTrue(RetryableError.serverError(status: 503).isRetryable)
        XCTAssertFalse(RetryableError.serverError(status: 404).isRetryable)
        XCTAssertFalse(RetryableError.exhausted.isRetryable)
    }

    func testRetrySucceedsAfterTransientFailures() async throws {
        let policy = BackoffPolicy(maxAttempts: 3, baseDelay: 0, multiplier: 1, maxDelay: 0)
        let counter = Counter()
        let result = try await withRetry(policy: policy, sleep: { _ in }) {
            let n = await counter.increment()
            if n < 3 { throw RetryableError.serverError(status: 500) }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        let total = await counter.value
        XCTAssertEqual(total, 3)
    }

    func testRetryGivesUpAfterMaxAttempts() async {
        let policy = BackoffPolicy(maxAttempts: 2, baseDelay: 0, multiplier: 1, maxDelay: 0)
        do {
            _ = try await withRetry(policy: policy, sleep: { _ in }) {
                throw RetryableError.serverError(status: 500)
            }
            XCTFail("Expected to throw")
        } catch {
            // expected
        }
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}
