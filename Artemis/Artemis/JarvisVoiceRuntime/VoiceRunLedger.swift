import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ArtemisBinaryFingerprint: Equatable, Sendable {
    let sha256: String
    let byteCount: Int64
    let fileNames: [String]
}

enum ArtemisBuildProvenance {
    static func capture() -> [String: String] {
        let bundle = Bundle.main
        let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            ?? bundle.executableURL?.lastPathComponent
            ?? "unknown"
        var fields = [
            "bundle_id": bundle.bundleIdentifier ?? "unknown",
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build_number": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "hardware_identifier": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
                ?? hardwareIdentifier(),
            "runtime_environment": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == nil
                ? "physical_device"
                : "simulator",
            "executable_name": executableName
        ]

        let debugDylib = bundle.bundleURL.appendingPathComponent("\(executableName).debug.dylib")
        let candidateURLs = [bundle.executableURL, debugDylib]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        do {
            let fingerprint = try binaryFingerprint(urls: candidateURLs)
            fields["binary_sha256"] = fingerprint.sha256
            fields["binary_bytes"] = String(fingerprint.byteCount)
            fields["binary_files"] = fingerprint.fileNames.joined(separator: ",")
            fields["binary_identity_status"] = "verified"
        } catch {
            fields["binary_identity_status"] = "failed"
            fields["binary_identity_error"] = error.localizedDescription
        }
        return fields
    }

    static func binaryFingerprint(urls: [URL]) throws -> ArtemisBinaryFingerprint {
        guard !urls.isEmpty else {
            throw NSError(
                domain: "ArtemisBuildProvenance",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No executable files were available to fingerprint"]
            )
        }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        var fileNames: [String] = []
        for url in urls {
            let fileName = url.lastPathComponent
            fileNames.append(fileName)
            hasher.update(data: Data(fileName.utf8))
            hasher.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                byteCount += Int64(chunk.count)
                hasher.update(data: chunk)
            }
        }
        return ArtemisBinaryFingerprint(
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: byteCount,
            fileNames: fileNames
        )
    }

    private static func hardwareIdentifier() -> String {
        #if canImport(Darwin)
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        #else
        return "unknown"
        #endif
    }
}

struct VoiceRunLedgerEvent: Codable, Sendable {
    let runID: UUID
    let event: String
    let receivedAt: Date
    let fields: [String: String]
}

extension Notification.Name {
    static let jarvisVoiceRuntimeEvent = Notification.Name("JarvisVoiceRuntimeEvent")
}

private struct VoiceRunManifest: Codable {
    let runID: UUID
    let startedAt: Date
    let relativeEventPath: String
}

/// Append-only, run-scoped local evidence. A scheduled audio buffer or a build
/// is never upgraded to a live-assistant claim by this ledger.
final class VoiceRunLedger {
    let runID: UUID
    private let evidenceDirectory: URL?
    private let runEventURL: URL?
    private let queue = DispatchQueue(label: "artemis.voice-ledger")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init() {
        let runID = UUID()
        self.runID = runID
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            evidenceDirectory = nil
            runEventURL = nil
            return
        }

        let evidenceDirectory = documents.appendingPathComponent("ArtemisEvidence", isDirectory: true)
        let runsDirectory = evidenceDirectory.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        let relativeEventPath = "runs/\(runID.uuidString).jsonl"
        let runEventURL = evidenceDirectory.appendingPathComponent(relativeEventPath)
        let manifest = VoiceRunManifest(
            runID: runID,
            startedAt: Date(),
            relativeEventPath: relativeEventPath
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.dateEncodingStrategy = .iso8601
        if let data = try? manifestEncoder.encode(manifest) {
            try? data.write(
                to: evidenceDirectory.appendingPathComponent("current-run.json"),
                options: .atomic
            )
        }
        self.evidenceDirectory = evidenceDirectory
        self.runEventURL = runEventURL
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        let entry = VoiceRunLedgerEvent(
            runID: runID,
            event: event,
            receivedAt: Date(),
            fields: fields
        )
        NotificationCenter.default.post(
            name: .jarvisVoiceRuntimeEvent,
            object: nil,
            userInfo: ["event": event, "fields": fields]
        )
        ArtemisRemoteLogSink.sendEvent(event, payload: fields)
        queue.async { [encoder, evidenceDirectory, runEventURL] in
            guard let data = try? encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8)?.appending("\n"),
                  let evidenceDirectory,
                  let runEventURL,
                  let lineData = line.data(using: .utf8) else {
                return
            }
            Self.append(lineData, to: evidenceDirectory.appendingPathComponent("voice-events.jsonl"))
            Self.append(lineData, to: runEventURL)
        }
    }

    func recordBuildProvenance() {
        Task { [weak self] in
            let fields = await Task.detached(priority: .utility) {
                ArtemisBuildProvenance.capture()
            }.value
            self?.record("build_provenance", fields: fields)
        }
    }

    private static func append(_ data: Data, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
