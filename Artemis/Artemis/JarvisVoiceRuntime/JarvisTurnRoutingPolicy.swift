import Foundation

enum JarvisBrainMode: String, CaseIterable, Identifiable, Sendable {
    case localGemma = "local_gemma"
    case codexBridge = "codex_bridge"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localGemma: "LOCAL GEMMA"
        case .codexBridge: "CODEX"
        }
    }

    var brainImplementation: String {
        switch self {
        case .localGemma: "gemma_e2b_litertlm"
        case .codexBridge: "codex_manager_proxy"
        }
    }

    var brainModel: String {
        switch self {
        case .localGemma: "gemma_e2b_imported_litertlm"
        case .codexBridge: "codex_low_latency_proxy"
        }
    }

    var brainRuntime: String {
        switch self {
        case .localGemma: "litert_lm_gpu"
        case .codexBridge: "m4_jarvis_bridge"
        }
    }

    static func launchSelection(arguments: [String]) -> JarvisBrainMode {
        if arguments.contains("--run-jarvis-local-gemma-loop") {
            return .localGemma
        }
        if arguments.contains("--run-jarvis-codex-bridge-loop")
            || arguments.contains("--run-jarvis-nano-bridge") {
            return .codexBridge
        }
        // DAT/HUD coexistence does not imply cloud inference. Local Gemma is
        // the default unless the launch contract explicitly selects Codex.
        return .localGemma
    }
}

enum JarvisVisualIntentAction: String, Sendable {
    case none
    case inspectCurrentView
    case startContinuousView
    case stopCamera
}

struct JarvisVisualIntentDecision: Equatable, Sendable {
    let action: JarvisVisualIntentAction
    let reason: String
    let explicitUserRequest: Bool

    var requiresVisualContext: Bool {
        action == .inspectCurrentView || action == .startContinuousView
    }
}

enum JarvisVisualIntentPolicy {
    static func decide(transcript: String) -> JarvisVisualIntentDecision {
        let text = normalized(transcript)
        guard !text.isEmpty else {
            return JarvisVisualIntentDecision(
                action: .none,
                reason: "empty_transcript",
                explicitUserRequest: false
            )
        }

        if containsAny(text, phrases: [
            "turn camera off", "turn the camera off", "stop camera", "stop the camera", "camera off",
            "stop looking", "stop watching"
        ]) {
            return JarvisVisualIntentDecision(
                action: .stopCamera,
                reason: "explicit_camera_stop",
                explicitUserRequest: true
            )
        }

        if containsAny(text, phrases: [
            "keep watching", "keep looking", "watch continuously", "watch this continuously",
            "stream camera", "stream the camera", "start camera", "start the camera",
            "turn camera on", "turn the camera on", "keep an eye on"
        ]) {
            return JarvisVisualIntentDecision(
                action: .startContinuousView,
                reason: "explicit_continuous_visual_request",
                explicitUserRequest: true
            )
        }

        // Discussing camera or vision engineering must not activate hardware.
        if containsAny(text, phrases: [
            "camera bug", "camera issue", "camera permission", "camera code",
            "camera api", "camera sdk", "vision model", "visual intent router",
            "screenshot discussion", "fix camera", "implement camera",
            "how does the camera work", "why did the camera"
        ]) {
            return JarvisVisualIntentDecision(
                action: .none,
                reason: "camera_discussion_not_capture",
                explicitUserRequest: false
            )
        }

        if containsAny(text, phrases: [
            "what do you see", "what can you see", "can you see", "do you see",
            "look at this", "look at that", "take a look", "check the camera",
            "check my camera", "check out the camera", "inspect the camera",
            "what is in front of me", "what's in front of me", "what is in front of you",
            "what's in front of you", "what am i looking at", "what is this",
            "what's this", "read this", "read the screen", "read what i see"
        ]) {
            return JarvisVisualIntentDecision(
                action: .inspectCurrentView,
                reason: "explicit_visual_question",
                explicitUserRequest: true
            )
        }

        return JarvisVisualIntentDecision(
            action: .none,
            reason: "no_explicit_visual_intent",
            explicitUserRequest: false
        )
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }
}

enum JarvisEngineeringIntentRoute: String, Sendable {
    case conversation
    case controlStop = "control_stop"
    case visualInspect = "visual_inspect"
    case visualWatch = "visual_watch"
    case visualStop = "visual_stop"
    case voiceDiagnostics = "voice_diagnostics"
    case projectContext = "project_context"
    case runtimeStatus = "runtime_status"
    case engineeringDelegate = "engineering_delegate"
    case clarify
}

struct JarvisEngineeringIntentDecision: Equatable, Sendable {
    let route: JarvisEngineeringIntentRoute
    let reason: String
    let confidence: Double
    let requiresContextMachine: Bool
    let requiresMeshRuntime: Bool
    let requiresCamera: Bool

    /// Stage 1.5 has not passed current-runtime proof. This classifier remains
    /// observable while deterministic product policies retain all authority.
    let sideEffectsAllowed: Bool
}

enum JarvisEngineeringIntentRouterV1 {
    static let schema = "jarvis_engineering_intent_shadow_v1"
    static let evidenceSource = "canonical_voice_transcript_corpus_plus_jarvis_product_contract"

    static func decide(
        transcript: String,
        visualDecision: JarvisVisualIntentDecision
    ) -> JarvisEngineeringIntentDecision {
        switch visualDecision.action {
        case .inspectCurrentView:
            return decision(
                .visualInspect,
                reason: visualDecision.reason,
                confidence: 1,
                requiresCamera: true
            )
        case .startContinuousView:
            return decision(
                .visualWatch,
                reason: visualDecision.reason,
                confidence: 1,
                requiresCamera: true
            )
        case .stopCamera:
            return decision(.visualStop, reason: visualDecision.reason, confidence: 1)
        case .none:
            break
        }

        let text = normalized(transcript)
        guard !text.isEmpty else {
            return decision(.clarify, reason: "empty_transcript", confidence: 1)
        }

        if isImmediateStop(text) {
            return decision(.controlStop, reason: "direct_current_turn_stop", confidence: 1)
        }

        if containsAny(text, phrases: [
            "what is running", "what's running", "which agents are active",
            "which tasks are active", "what tasks are active", "active threads",
            "what is blocked", "what's blocked", "what needs me", "needs user",
            "worker status", "thread status", "process status", "is the worker running",
            "are any workers running", "what is currently consuming tokens"
        ]) {
            return decision(
                .runtimeStatus,
                reason: "explicit_runtime_truth_request",
                confidence: 0.98,
                requiresMeshRuntime: true
            )
        }

        if containsAny(text, phrases: [
            "tell codex", "ask codex", "have codex", "send this to codex",
            "tell the worker", "ask the worker", "have the worker", "queue this",
            "steer the", "steer this", "delegate this", "hand this to",
            "implement this", "fix this in the", "fix the camera", "fix camera",
            "make this change"
        ]) {
            return decision(
                .engineeringDelegate,
                reason: "explicit_engineering_handoff_language",
                confidence: 0.96,
                requiresContextMachine: true,
                requiresMeshRuntime: true
            )
        }

        if isVoiceDiagnostic(text) {
            return decision(
                .voiceDiagnostics,
                reason: "voice_runtime_symptom_or_metric_request",
                confidence: 0.94
            )
        }

        if containsAny(text, phrases: [
            "what are we working on", "what're we working on", "where are we on",
            "why are we doing this", "why does this matter", "what happened before",
            "what changed", "what did we decide", "what should we do next",
            "what should we build next", "what is next", "what's next",
            "do you remember", "what did i ask before", "recall our",
            "project history", "project context"
        ]) {
            return decision(
                .projectContext,
                reason: "explicit_project_memory_or_next_step_request",
                confidence: 0.96,
                requiresContextMachine: true
            )
        }

        if isClippedReference(text) {
            return decision(.clarify, reason: "short_ambiguous_reference", confidence: 0.82)
        }

        return decision(.conversation, reason: "no_tool_or_context_intent", confidence: 0.72)
    }

    private static func decision(
        _ route: JarvisEngineeringIntentRoute,
        reason: String,
        confidence: Double,
        requiresContextMachine: Bool = false,
        requiresMeshRuntime: Bool = false,
        requiresCamera: Bool = false
    ) -> JarvisEngineeringIntentDecision {
        JarvisEngineeringIntentDecision(
            route: route,
            reason: reason,
            confidence: confidence,
            requiresContextMachine: requiresContextMachine,
            requiresMeshRuntime: requiresMeshRuntime,
            requiresCamera: requiresCamera,
            sideEffectsAllowed: false
        )
    }

    private static func isImmediateStop(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        let controls: Set<String> = ["stop", "wait", "pause", "cancel", "enough", "listen"]
        let permitted = controls.union(["please", "hey", "jarvis", "now", "answer", "response", "speaking", "that", "do", "not", "continue", "and", "to", "me", "hold", "on"])
        return !Set(words).isDisjoint(with: controls) && Set(words).isSubset(of: permitted)
    }

    private static func isVoiceDiagnostic(_ text: String) -> Bool {
        let symptoms = [
            "can you hear me", "cannot hear", "can't hear", "did not hear", "didn't hear",
            "not hearing me", "microphone not", "mic cut", "speech got cut", "transcript cut",
            "speech recognition", "stt ", "text to speech", "tts ", "voice went quiet",
            "reply is silent", "response is silent", "audio route", "wrong route",
            "pronounced", "pronunciation", "barge in", "listening to itself",
            "first audio", "voice latency", "speech latency", "where are we on latency"
        ]
        return containsAny(text, phrases: symptoms)
    }

    private static func isClippedReference(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count <= 4 else { return false }
        let references: Set<String> = ["this", "that", "it", "there", "which", "what"]
        return !Set(words.map(String.init)).isDisjoint(with: references)
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }
}

struct JarvisVisualEvidence: Equatable, Sendable {
    let source: String
    let captureMode: String
    let evidenceClass: String
    let model: String
    let runtime: String
    let quantization: String
    let frameID: Int
    let frameAgeMilliseconds: Int
    let inferenceMilliseconds: Int
    let summary: String
    let visibleText: String
    let uncertainty: String
    let confidence: Double
    let directClaimAllowed: Bool

    var promptContext: String {
        let text = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rendered = """
        FRESH VISUAL EVIDENCE (not direct model vision): source=\(source), capture=\(captureMode), evidence_class=\(evidenceClass), frame=\(frameID), age_ms=\(frameAgeMilliseconds), analyzer=\(model), runtime=\(runtime), quantization=\(quantization), inference_ms=\(inferenceMilliseconds), confidence=\(String(format: "%.2f", confidence)), direct_claim_allowed=\(directClaimAllowed). Scene: \(summary)\(text.isEmpty ? "" : " Visible text: \(text)") Uncertainty: \(uncertainty). If direct_claim_allowed is false, explicitly qualify the observation or ask for a better view. Do not claim anything beyond this evidence.
        """
        return String(rendered.prefix(1_200))
    }
}

enum JarvisVisualContextError: LocalizedError, Equatable {
    case providerUnavailable
    case cameraNotReady(String)
    case noFreshFrame(String)
    case analysisFailed(String)
    case controlFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            "Jarvis visual context is not connected."
        case let .cameraNotReady(reason):
            "The glasses camera is not ready: \(reason)"
        case let .noFreshFrame(reason):
            "No fresh glasses frame is available: \(reason)"
        case let .analysisFailed(reason):
            "The local vision model could not analyze the frame: \(reason)"
        case let .controlFailed(reason):
            "The camera request could not be completed: \(reason)"
        }
    }
}
