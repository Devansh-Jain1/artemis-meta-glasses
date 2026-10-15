import Foundation

enum WearablePowerMode: String, Equatable, Sendable {
    case normal
    case conserve
    case critical

    var label: String {
        switch self {
        case .normal:
            return "Normal"
        case .conserve:
            return "Conserve"
        case .critical:
            return "Critical"
        }
    }
}

struct WearablePowerDecision: Equatable, Sendable {
    let mode: WearablePowerMode
    let reason: String
    let cameraFrameRate: Int
    let minimumHUDIntervalSeconds: TimeInterval
    let allowsCameraStart: Bool
}

enum WearablePowerPolicy {
    // The live DAT path is validated at 24 fps. Lower arbitrary values caused
    // the device stream to terminate with videoStreamingError before frame 1.
    // Conserve camera power by shortening/duty-cycling sessions, not by sending
    // an unsupported stream configuration to the glasses.
    static let defaultCameraFrameRate = 24
    static let conserveCameraFrameRate = 24
    static let normalHUDIntervalSeconds: TimeInterval = 2.0
    static let conserveHUDIntervalSeconds: TimeInterval = 5.0
    static let criticalHUDIntervalSeconds: TimeInterval = 12.0

    static func decision(
        phoneLowPowerMode: Bool,
        phoneThermalState: String,
        wearableThermalLevel: String,
        latestPowerFault: String?,
        cameraRequested: Bool
    ) -> WearablePowerDecision {
        let normalizedFault = normalizedFault(latestPowerFault)
        let normalizedPhoneThermal = phoneThermalState.lowercased()
        let normalizedWearableThermal = wearableThermalLevel.lowercased()

        if let normalizedFault, isCriticalFault(normalizedFault) {
            return WearablePowerDecision(
                mode: .critical,
                reason: normalizedFault,
                cameraFrameRate: 0,
                minimumHUDIntervalSeconds: criticalHUDIntervalSeconds,
                allowsCameraStart: false
            )
        }

        if isCriticalWearableThermal(normalizedWearableThermal) {
            return WearablePowerDecision(
                mode: .critical,
                reason: "wearable_thermal_\(normalizedWearableThermal)",
                cameraFrameRate: 0,
                minimumHUDIntervalSeconds: criticalHUDIntervalSeconds,
                allowsCameraStart: false
            )
        }

        if normalizedPhoneThermal == "critical" {
            return WearablePowerDecision(
                mode: .critical,
                reason: "phone_thermal_critical",
                cameraFrameRate: 0,
                minimumHUDIntervalSeconds: criticalHUDIntervalSeconds,
                allowsCameraStart: false
            )
        }

        if phoneLowPowerMode {
            return conserve(reason: "phone_low_power_mode")
        }

        if normalizedPhoneThermal == "serious" {
            return conserve(reason: "phone_thermal_serious")
        }

        if isConserveWearableThermal(normalizedWearableThermal) {
            return conserve(reason: "wearable_thermal_\(normalizedWearableThermal)")
        }

        if let normalizedFault {
            return conserve(reason: normalizedFault)
        }

        return WearablePowerDecision(
            mode: .normal,
            reason: cameraRequested ? "camera_requested" : "idle",
            cameraFrameRate: defaultCameraFrameRate,
            minimumHUDIntervalSeconds: normalHUDIntervalSeconds,
            allowsCameraStart: true
        )
    }

    static func normalizedFault(_ fault: String?) -> String? {
        guard let fault else { return nil }
        let normalized = fault
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return normalized.isEmpty || normalized == "none" ? nil : normalized
    }

    static func isCriticalFault(_ fault: String) -> Bool {
        let normalized = normalizedFault(fault) ?? fault.lowercased()
        return normalized.contains("battery_critical")
            || normalized.contains("peak_power_shutdown")
            || normalized.contains("thermal_emergency")
            || normalized.contains("thermal_critical")
    }

    private static func conserve(reason: String) -> WearablePowerDecision {
        WearablePowerDecision(
            mode: .conserve,
            reason: reason,
            cameraFrameRate: conserveCameraFrameRate,
            minimumHUDIntervalSeconds: conserveHUDIntervalSeconds,
            allowsCameraStart: true
        )
    }

    private static func isConserveWearableThermal(_ thermal: String) -> Bool {
        thermal == "moderate" || thermal == "severe"
    }

    private static func isCriticalWearableThermal(_ thermal: String) -> Bool {
        thermal == "critical" || thermal == "emergency" || thermal == "shutdown"
    }
}
