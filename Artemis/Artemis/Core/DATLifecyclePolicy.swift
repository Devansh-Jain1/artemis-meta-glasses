import Foundation

enum DATLifecycleState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case streaming
    case degraded
    case stale
}

enum DATLifecycleEvent: Equatable, Sendable {
    case startRequested
    case freshFrameReceived
    case staleFrameObserved
    case streamStopped
    case deviceUnavailable
    case userStopped
}

struct DATLifecycleDecision: Equatable, Sendable {
    let state: DATLifecycleState
    let reason: String
    let acceptLiveVisualContext: Bool
    let deviceUnavailableReason: String
    let telemetry: [String: String]
}

struct DATFrameMetrics: Equatable, Sendable {
    let frameAgeMS: Int
    let ingestLatencyMS: Int
    let droppedFrames: Int
    let isFresh: Bool
}

enum DATLifecyclePolicy {
    static let defaultStaleAfterMS = 2_500
    static let defaultMaxReconnectAttempts = 4

    static func transition(
        from state: DATLifecycleState,
        event: DATLifecycleEvent,
        deviceUnavailableReason: String,
        thermalState: String,
        appLifecycleState: String
    ) -> DATLifecycleDecision {
        let nextState: DATLifecycleState
        let reason: String
        let acceptsLiveVisualContext: Bool

        switch event {
        case .startRequested:
            nextState = .connecting
            reason = "dat_start_requested"
            acceptsLiveVisualContext = false
        case .freshFrameReceived:
            nextState = .streaming
            reason = state == .degraded ? "dat_recovered_with_fresh_frame" : "dat_fresh_frame_received"
            acceptsLiveVisualContext = true
        case .staleFrameObserved:
            nextState = .stale
            reason = "dat_stale_frame_observed"
            acceptsLiveVisualContext = false
        case .streamStopped:
            nextState = .stale
            reason = "dat_stream_stopped"
            acceptsLiveVisualContext = false
        case .deviceUnavailable:
            nextState = .degraded
            reason = "dat_device_unavailable"
            acceptsLiveVisualContext = false
        case .userStopped:
            nextState = .disconnected
            reason = "dat_user_stopped"
            acceptsLiveVisualContext = false
        }

        return DATLifecycleDecision(
            state: nextState,
            reason: reason,
            acceptLiveVisualContext: acceptsLiveVisualContext,
            deviceUnavailableReason: deviceUnavailableReason,
            telemetry: [
                "dat_lifecycle_state": nextState.rawValue,
                "dat_lifecycle_reason": reason,
                "dat_device_unavailable_reason": deviceUnavailableReason,
                "thermal_state": thermalState,
                "app_lifecycle_state": appLifecycleState
            ]
        )
    }

    static func frameMetrics(
        frameID: Int,
        previousFrameID: Int,
        sourceTimestampMS: Int,
        ingestTimestampMS: Int,
        nowMS: Int,
        staleAfterMS: Int = defaultStaleAfterMS
    ) -> DATFrameMetrics {
        let frameAgeMS = sourceTimestampMS > 0 ? max(0, nowMS - sourceTimestampMS) : Int.max
        let ingestLatencyMS = sourceTimestampMS > 0 ? max(0, ingestTimestampMS - sourceTimestampMS) : Int.max
        let droppedFrames = previousFrameID > 0 ? max(0, frameID - previousFrameID - 1) : 0
        return DATFrameMetrics(
            frameAgeMS: frameAgeMS,
            ingestLatencyMS: ingestLatencyMS,
            droppedFrames: droppedFrames,
            isFresh: sourceTimestampMS > 0 && frameAgeMS <= staleAfterMS
        )
    }

    static func reconnectDelaySeconds(attempt: Int, maxAttempts: Int = defaultMaxReconnectAttempts) -> Double? {
        guard attempt > 0, attempt < maxAttempts else { return nil }
        return min(pow(2.0, Double(attempt - 1)), 8.0)
    }
}
