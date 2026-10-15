import Foundation

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TestDATRetryPolicy {
    static func main() {
        expect(
            DATStartRetryPolicy.decision(
                errorDescription: "PermissionError(rawValue: 0) [raw=0]: No Meta wearable is visible to the permission flow.",
                isPersistentEligibilityRetryEnabled: false,
                attempt: 5,
                maxAttempts: 5
            ) == .fail,
            "non-persistent mode should stop at the final max-attempt visibility failure"
        )

        expect(
            DATStartRetryPolicy.decision(
                errorDescription: "PermissionError(rawValue: 0) [raw=0]: No Meta wearable is visible to the permission flow.",
                isPersistentEligibilityRetryEnabled: true,
                attempt: 5,
                maxAttempts: 5
            ) == .retry(afterSeconds: 5),
            "persistent mode should keep retrying visibility failures beyond max attempts"
        )

        expect(
            DATStartRetryPolicy.decision(
                errorDescription: "PermissionError(rawValue: 6) [raw=6]: Meta DAT reported an internal permission error.",
                isPersistentEligibilityRetryEnabled: true,
                attempt: 2,
                maxAttempts: 5
            ) == .fail,
            "persistent mode should still fail hard on non-retryable permission errors"
        )

        print("PASS: dat retry policy")
    }
}
