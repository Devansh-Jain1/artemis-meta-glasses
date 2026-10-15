import Foundation

struct DATRuntimeEnvironmentSnapshot {
    static let lastSuccessfulFrameTimestampKey = "jarvis.dat.last_successful_frame_timestamp"

    let bundleID: String
    let appVersion: String
    let buildNumber: String
    let datSDKVersion: String
    let previousSuccessfulFrameAt: String

    static func current(defaults: UserDefaults = .standard) -> DATRuntimeEnvironmentSnapshot {
        DATRuntimeEnvironmentSnapshot(
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            datSDKVersion: detectedDATSDKVersion(),
            previousSuccessfulFrameAt: lastSuccessfulFrameISO8601(defaults: defaults)
        )
    }

    static func recordSuccessfulFrame(at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: lastSuccessfulFrameTimestampKey)
    }

    static func classifyFailure(
        registrationReady: Bool,
        permissionState: String,
        eligibleDevice: Bool,
        framesReceived: Int,
        errorDescription: String
    ) -> String {
        let normalizedPermission = permissionState.lowercased()
        let normalizedError = errorDescription.lowercased()

        if !registrationReady { return "registration_not_ready" }
        if !normalizedPermission.contains("granted") { return "camera_permission_not_granted" }
        if !eligibleDevice { return "no_eligible_device" }
        if normalizedError.contains("datappontheglassesupdaterequired")
            || normalizedError.contains("dat app on the glasses") {
            return "dat_glasses_app_update_required"
        }
        if normalizedError.contains("batterycritical") || normalizedError.contains("battery critical") {
            return "wearable_battery_critical"
        }
        if normalizedError.contains("thermal") { return "wearable_thermal_rejection" }
        if normalizedError.contains("peakpowershutdown") || normalizedError.contains("peak power") {
            return "wearable_peak_power_shutdown"
        }
        if normalizedError.contains("session ended by device") {
            return "session_ended_by_device"
        }
        if framesReceived == 0 && normalizedError.contains("videostreamingerror") {
            return "camera_rejected_before_first_frame"
        }
        if framesReceived == 0 { return "no_first_frame_unknown" }
        return "stream_failed_after_frames"
    }

    var payload: [String: Any] {
        [
            "app_bundle_id": bundleID,
            "app_version": appVersion,
            "app_build": buildNumber,
            "dat_sdk_version": datSDKVersion,
            "previous_successful_frame_at": previousSuccessfulFrameAt
        ]
    }

    private static func detectedDATSDKVersion() -> String {
        let framework = Bundle(identifier: "com.facebook.MWDATCore")
            ?? Bundle.allFrameworks.first { $0.bundleIdentifier == "com.facebook.MWDATCore" }
        return framework?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    private static func lastSuccessfulFrameISO8601(defaults: UserDefaults) -> String {
        let timestamp = defaults.double(forKey: lastSuccessfulFrameTimestampKey)
        guard timestamp > 0 else { return "none_recorded" }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp))
    }
}

struct DATWearableDiagnosticSnapshot: Sendable {
    let permissionState: String
    let eligibleDevice: Bool
    let eligibilitySummary: String
    let sessionState: String
    let streamState: String
    let displayState: String
    let lastError: String
}
