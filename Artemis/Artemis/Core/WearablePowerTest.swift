import Foundation

enum WearablePowerTestPhase: String, CaseIterable, Codable, Identifiable, Sendable {
    case bluetoothIdle = "bluetooth_idle"
    case jarvisConnected = "jarvis_connected"
    case datSessionIdle = "dat_session_idle"
    case displaySparse = "display_sparse"
    case displayCard = "display_card"
    case cameraBurst = "camera_burst"
    case cameraContinuous = "camera_continuous"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bluetoothIdle: return "Bluetooth idle"
        case .jarvisConnected: return "Jarvis connected"
        case .datSessionIdle: return "DAT session idle"
        case .displaySparse: return "Sparse display"
        case .displayCard: return "Card display"
        case .cameraBurst: return "Camera burst"
        case .cameraContinuous: return "Camera continuous"
        }
    }
}

struct WearablePowerRuntimeSnapshot: Codable, Equatable, Sendable {
    let sessionActive: Bool
    let cameraActive: Bool
    let displayActive: Bool
    let displayState: String
}

struct WearablePowerSample: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let phase: WearablePowerTestPhase
    let batteryPercent: Int
    let batterySource: String
    let jarvisValidationRunning: Bool
    let wearableConnectionState: String
    let wearableThermalLevel: String
    let wearablePowerMode: String
    let phoneBattery: String
    let phoneThermalState: String
    let runtime: WearablePowerRuntimeSnapshot
}

struct WearablePowerDrainSummary: Equatable, Sendable {
    let phase: WearablePowerTestPhase
    let startPercent: Int
    let endPercent: Int
    let elapsedSeconds: TimeInterval
    let percentPerHour: Double

    var label: String {
        let minutes = elapsedSeconds / 60
        return String(
            format: "%@ %.1f%%/h (%d%% -> %d%%, %.1f min)",
            phase.label,
            percentPerHour,
            startPercent,
            endPercent,
            minutes
        )
    }
}

enum WearablePowerTestMath {
    static func latestDrainSummary(samples: [WearablePowerSample]) -> WearablePowerDrainSummary? {
        guard let latest = samples.last else { return nil }
        guard let earlier = samples.dropLast().last(where: {
            $0.phase == latest.phase && $0.recordedAt < latest.recordedAt
        }) else {
            return nil
        }

        let elapsed = latest.recordedAt.timeIntervalSince(earlier.recordedAt)
        guard elapsed >= 60 else { return nil }
        let drop = max(0, earlier.batteryPercent - latest.batteryPercent)
        let percentPerHour = Double(drop) * 3_600 / elapsed
        return WearablePowerDrainSummary(
            phase: latest.phase,
            startPercent: earlier.batteryPercent,
            endPercent: latest.batteryPercent,
            elapsedSeconds: elapsed,
            percentPerHour: percentPerHour
        )
    }
}

enum WearablePowerSampleLog {
    static func append(_ sample: WearablePowerSample, fileManager: FileManager = .default) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("JarvisPowerTests", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("wearable-power-samples.jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(sample)
        data.append(0x0A)

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
        return fileURL
    }
}
