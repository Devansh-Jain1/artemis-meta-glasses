import Combine
import Foundation

@MainActor
final class HUDControlVoiceAnnouncer: NSObject, ObservableObject, SpeechOutputServiceDelegate {
    @Published private(set) var statusText = "Jarvis voice idle"

    private let speechOutput = SpeechOutputService()
    private let engine: SpeechOutputEngine = .kokoroLocal
    private var lastSpokenText = ""
    private var lastSpokenAt = Date.distantPast

    override init() {
        super.init()
        speechOutput.delegate = self
        speechOutput.enablePrivateGlassesDuplexRoute()
        ArtemisRemoteLogSink.send("[HUDControlVoice] route_mode=private_glasses_duplex")
    }

    func speak(_ text: String, reason: String) {
        let clean = sanitize(text, limit: 260)
        guard !clean.isEmpty else { return }
        if clean == lastSpokenText && Date().timeIntervalSince(lastSpokenAt) < 8 {
            ArtemisRemoteLogSink.send("[HUDControlVoice] speak_skipped duplicate reason=\(reason)")
            return
        }

        lastSpokenText = clean
        lastSpokenAt = Date()
        statusText = "Jarvis speaking"
        ArtemisRemoteLogSink.send("[HUDControlVoice] speak_requested engine=\(engine.rawValue) route=private_glasses_duplex reason=\(reason) chars=\(clean.count) text=\(clean)")
        speechOutput.speak(clean, engine: engine)
    }

    func stop() {
        speechOutput.stop()
        statusText = "Jarvis voice stopped"
        ArtemisRemoteLogSink.send("[HUDControlVoice] stopped engine=\(engine.rawValue)")
    }

    func speechOutputDidStart(text: String, engine: SpeechOutputEngine) {
        statusText = "Jarvis speaking"
        ArtemisRemoteLogSink.send("[HUDControlVoice] speak_started engine=\(engine.rawValue) chars=\(text.count)")
    }

    func speechOutputDidGenerate(text: String, engine: SpeechOutputEngine, stats: KokoroSpeechPlaybackStats) {
        let message = "[HUDControlVoice] generated engine=\(engine.rawValue) voice=\(stats.voiceName) generation_ms=\(stats.generationMilliseconds) audio_s=\(String(format: "%.2f", stats.audioDurationSeconds)) rtf=\(String(format: "%.2f", stats.realTimeFactor)) route=\(stats.audioRoute)"
        ArtemisRemoteLogSink.send(message)
    }

    func speechOutputDidFinish(text: String, engine: SpeechOutputEngine) {
        statusText = "Jarvis voice idle"
        ArtemisRemoteLogSink.send("[HUDControlVoice] speak_finished engine=\(engine.rawValue) chars=\(text.count)")
    }

    func speechOutputDidFail(text: String, engine: SpeechOutputEngine, error: Error) {
        statusText = "Jarvis voice failed"
        ArtemisRemoteLogSink.send("[HUDControlVoice] speak_failed engine=\(engine.rawValue) chars=\(text.count) error=\(describeSpeechRuntimeError(error))")
    }

    private func sanitize(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
