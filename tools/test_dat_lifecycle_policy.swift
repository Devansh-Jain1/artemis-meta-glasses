import Foundation

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TestDATLifecyclePolicy {
    static func main() {
        let connecting = DATLifecyclePolicy.transition(
            from: .disconnected,
            event: .startRequested,
            deviceUnavailableReason: "none",
            thermalState: "nominal",
            appLifecycleState: "active"
        )
        expect(connecting.state == .connecting, "start request should enter connecting")

        let streaming = DATLifecyclePolicy.transition(
            from: .connecting,
            event: .freshFrameReceived,
            deviceUnavailableReason: "none",
            thermalState: "nominal",
            appLifecycleState: "active"
        )
        expect(streaming.state == .streaming, "fresh frame should enter streaming")
        expect(streaming.acceptLiveVisualContext, "fresh streaming frame should be accepted")

        let stale = DATLifecyclePolicy.transition(
            from: .streaming,
            event: .staleFrameObserved,
            deviceUnavailableReason: "none",
            thermalState: "nominal",
            appLifecycleState: "active"
        )
        expect(stale.state == .stale, "stale frame should enter stale state")
        expect(!stale.acceptLiveVisualContext, "stale frame must be rejected for live vision")

        let degraded = DATLifecyclePolicy.transition(
            from: .streaming,
            event: .deviceUnavailable,
            deviceUnavailableReason: "no_eligible_device",
            thermalState: "serious",
            appLifecycleState: "background"
        )
        expect(degraded.state == .degraded, "device unavailable should enter degraded")
        expect(degraded.deviceUnavailableReason == "no_eligible_device", "device unavailable reason should be preserved")
        expect(degraded.telemetry["thermal_state"] == "serious", "thermal state should be logged")
        expect(degraded.telemetry["app_lifecycle_state"] == "background", "background state should be logged")

        let metrics = DATLifecyclePolicy.frameMetrics(
            frameID: 8,
            previousFrameID: 5,
            sourceTimestampMS: 1_000,
            ingestTimestampMS: 1_100,
            nowMS: 1_200
        )
        expect(metrics.droppedFrames == 2, "frame id gap should count dropped frames")
        expect(metrics.frameAgeMS == 200, "frame age should be calculated from source timestamp")
        expect(metrics.ingestLatencyMS == 100, "ingest latency should be calculated from source to ingest")
        expect(metrics.isFresh, "young frame should be fresh")

        let staleMetrics = DATLifecyclePolicy.frameMetrics(
            frameID: 9,
            previousFrameID: 8,
            sourceTimestampMS: 1_000,
            ingestTimestampMS: 1_100,
            nowMS: 3_700
        )
        expect(!staleMetrics.isFresh, "old frame should be stale")

        expect(DATLifecyclePolicy.reconnectDelaySeconds(attempt: 1, maxAttempts: 4) == 1, "attempt 1 backoff")
        expect(DATLifecyclePolicy.reconnectDelaySeconds(attempt: 3, maxAttempts: 4) == 4, "attempt 3 backoff")
        expect(DATLifecyclePolicy.reconnectDelaySeconds(attempt: 4, maxAttempts: 4) == nil, "max attempts should stop reconnect")

        print("PASS: dat lifecycle policy")
    }
}
