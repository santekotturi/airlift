import Foundation

/// Exponential backoff policy for retrying flaky requests.
///
/// The Google Health *sleep* endpoint has thrown intermittent 500s during the
/// migration period (PRD §4/§9), so sleep reads must be retried. On exhaustion
/// the caller leaves the sync window unadvanced and tries again next cycle —
/// never silently advancing past a failed window.
struct BackoffPolicy: Sendable {
    var maxAttempts: Int
    var baseDelay: TimeInterval
    var multiplier: Double
    var maxDelay: TimeInterval

    static let sleepReads = BackoffPolicy(
        maxAttempts: 3,
        baseDelay: 1.0,
        multiplier: 2.0,
        maxDelay: 30.0
    )

    /// Delay before the given retry attempt (1-based). Includes ±20% jitter to
    /// avoid synchronized retries. `jitterFraction` is injectable for tests.
    func delay(forAttempt attempt: Int, jitterFraction: Double = Double.random(in: -0.2...0.2)) -> TimeInterval {
        let exponential = baseDelay * pow(multiplier, Double(attempt - 1))
        let capped = min(exponential, maxDelay)
        return max(0, capped * (1 + jitterFraction))
    }
}

/// Runs `operation`, retrying when it throws a `RetryableError`.
/// Non-retryable errors propagate immediately.
func withRetry<T>(
    policy: BackoffPolicy,
    sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 1...policy.maxAttempts {
        do {
            return try await operation()
        } catch let error as RetryableError where error.isRetryable {
            lastError = error
            Log.api.warning("Retryable failure on attempt \(attempt)/\(policy.maxAttempts): \(error.localizedDescription)")
            if attempt < policy.maxAttempts {
                try await sleep(policy.delay(forAttempt: attempt))
            }
        }
    }
    throw lastError ?? RetryableError.exhausted
}

/// Errors that may be retried (5xx, transient transport failures).
enum RetryableError: Error, LocalizedError {
    case serverError(status: Int)
    case transport(Error)
    case exhausted

    var isRetryable: Bool {
        switch self {
        case .serverError(let status): return (500..<600).contains(status)
        case .transport: return true
        case .exhausted: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .serverError(let status): return "Server returned HTTP \(status)."
        case .transport(let error): return "Network error: \(error.localizedDescription)"
        case .exhausted: return "Retries exhausted."
        }
    }
}
