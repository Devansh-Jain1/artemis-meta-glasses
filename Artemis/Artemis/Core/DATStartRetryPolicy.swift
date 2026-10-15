import Foundation

enum DATStartRetryDecision: Equatable {
    case retry(afterSeconds: TimeInterval)
    case fail
}

enum DATStartRetryPolicy {
    static func decision(
        errorDescription: String,
        isPersistentEligibilityRetryEnabled: Bool,
        attempt: Int,
        maxAttempts: Int
    ) -> DATStartRetryDecision {
        let lower = errorDescription.lowercased()
        let isVisibilityOrEligibilityIssue =
            lower.contains("permissionerror(rawvalue: 0)") ||
            lower.contains("no meta wearable is visible") ||
            lower.contains("nodevice") ||
            lower.contains("noeligibledevice")

        if isPersistentEligibilityRetryEnabled && isVisibilityOrEligibilityIssue {
            return .retry(afterSeconds: min(Double(max(attempt, 1)), 5.0))
        }

        guard attempt < maxAttempts else { return .fail }

        if isVisibilityOrEligibilityIssue ||
            lower.contains("requestinprogress") ||
            lower.contains("requesttimeout") ||
            lower.contains("connectionerror") ||
            lower.contains("sessionalreadyexists") ||
            lower.contains("dwaunavailable") {
            return .retry(afterSeconds: Double(max(attempt, 1)))
        }

        return .fail
    }
}
