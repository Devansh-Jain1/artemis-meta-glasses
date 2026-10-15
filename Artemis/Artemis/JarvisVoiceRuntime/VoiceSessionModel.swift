import Combine
import AVFoundation
import Foundation

@MainActor
final class VoiceSessionModel: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case userSpeaking
        case responding
        case unavailable(String)

        var label: String {
            switch self {
            case .idle: "Ready"
            case .starting: "Starting microphone"
            case .listening: "Listening"
            case .userSpeaking: "Hearing you"
            case .responding: "Jarvis is thinking"
            case let .unavailable(reason): reason
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var draftTranscript = ""
    @Published private(set) var conversation: [ConversationLine] = []
    @Published private(set) var semanticRouterStatus = "EmbeddingGemma unavailable"
    @Published private(set) var sttRuntimeStatus = "Parakeet EOU not prepared"
    @Published private(set) var brainStatus = "Gemma E2B unavailable"
    @Published private(set) var ttsStatus = "Supertonic ready"
    @Published private(set) var latestAudioLevel: Float = 0
    @Published private(set) var microphoneReady = false
    @Published private(set) var recognizerProven = false
    @Published private(set) var brainMode: JarvisBrainMode
    @Published private(set) var jarvisStatus = "Local Gemma selected"

    var jarvisModeEnabled: Bool { brainMode == .codexBridge }

    private let audio: FullDuplexAudioCoordinator
    private let speechInput: ParakeetSpeechInput
    private let ledger = VoiceRunLedger()
    private let conversationStore = ConversationStore()
    private let semanticRouter = EmbeddingGemmaIntentRouter()
    private let brain = GemmaBrainService()
    private let tts: SupertonicSpeechOutput
    private let nanoTTS: JarvisVoiceNanoRemoteSpeechOutput?
    private let nanoTTSModeEnabled: Bool
    private let nanoTTSConfigurationError: String?
    private let jarvis = JarvisBridgeClient()
    private let experimentalSemanticRouterEnabled = ProcessInfo.processInfo.arguments.contains(
        "--enable-experimental-semantic-router"
    ) || ProcessInfo.processInfo.arguments.contains("--semantic-router-probe-only")
    private var jarvisTask: Task<Void, Never>?
    private var jarvisInboxTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var brainWarmTask: Task<Void, Never>?
    private var brainTask: Task<Void, Never>?
    private var speechRecoveryTask: Task<Void, Never>?
    private var adaptiveRouteRecoveryTask: Task<Void, Never>?
    private var adaptiveRouteRecoveryPending = false
    private var audioRouteCancellable: AnyCancellable?
    private var semanticRouterWarmTask: Task<Void, Never>?
    private var latestJarvisMessageID: UInt64 = UInt64(
        UserDefaults.standard.string(forKey: "jarvis.latestInboundMessageID") ?? "0"
    ) ?? 0
    private var finalizedTranscriptForTurn: String?
    private var ttsIsSpeaking = false
    private var speechStartedAt: Date?
    private var activeTurnID: UUID?
    private var activeTurnStartedAt: Date?
    private var activeTurnFinalizedAt: Date?
    private var firstBrainFragmentAt: Date?
    private var endpointTask: Task<Void, Never>?
    private var vadSpeechActive = false
    private var pendingBargeIn = false
    private var bargeInCandidateStartedAt: Date?
    private var appleSpeechActivityCandidate = false
    private var appleSpeechActivityTimeoutTask: Task<Void, Never>?
    private var activeAssistantResponse = ""
    private var activeVisualEvidence: JarvisVisualEvidence?
    private var turnGeneration = 0
    private var sileroVADReady = false
    private var visualContextProvider: ((
        String,
        UUID,
        JarvisVisualIntentDecision
    ) async throws -> JarvisVisualEvidence?)?
    private var lastVADProbabilityTelemetryAt = Date.distantPast
    private var lastAudioLevelTelemetryAt = Date.distantPast
    private var currentVADSpeechStartedAt: Date?
    private var currentVADMaximumProbability: Float = 0
    private var consecutiveMeaningfulSegmentsWithoutTranscript = 0
    private var ttsWarmProbeStarted = false
    private var ttsWarmProbeFinished = false
    private var semanticRouterWarmed = false
    private var pendingJarvisInboundMessages: [JarvisInboundMessage] = []
    private var completedJarvisRequestCounts: [String: Int] = [:]
    private var activeJarvisStreamRequestID: String?
    private var activeJarvisStreamSessionID: UUID?
    private var activeJarvisStreamTurnID: UUID?
    private var activeJarvisStreamGeneration = 0
    private var activeJarvisStreamReceivedSequences = Set<Int>()
    private var activeJarvisConversationLineIndex: Int?
    private var currentJarvisRequestID: String?
    private var discardedJarvisRequestIDs = Set<String>()

    private let hybridEndpointDelayNanoseconds: UInt64 = 700_000_000

    var visibleStatus: String {
        if phase == .responding, microphoneReady { return "Listening while responding" }
        if phase == .listening, microphoneReady, !recognizerProven { return "Microphone active" }
        return phase.label
    }

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        let nanoTTSModeEnabled = arguments.contains("--run-jarvis-nano-bridge")
        let initialBrainMode = JarvisBrainMode.launchSelection(arguments: arguments)
        brainMode = initialBrainMode
        let audioLaunchSelection = ArtemisJarvisAudioLaunchPolicy()
            .selection(arguments: arguments)
        let routeMode: FullDuplexAudioRouteMode
        switch audioLaunchSelection.profile {
        case .builtInSpeaker:
            routeMode = .builtInSpeaker
        case .callFree:
            routeMode = .callFreeJarvis
        case .adaptiveHFP:
            routeMode = .adaptiveJarvis
        }
        let audio = FullDuplexAudioCoordinator(routeMode: routeMode)
        self.audio = audio
        speechInput = ParakeetSpeechInput(audio: audio)
        tts = SupertonicSpeechOutput(audio: audio)
        self.nanoTTSModeEnabled = nanoTTSModeEnabled
        if nanoTTSModeEnabled {
            do {
                guard NanoRemoteTTSLaunchContract.isSatisfied(arguments: arguments) else {
                    throw NanoRemoteTTSError.invalidConfiguration(
                        "requires_jarvis_codex_bridge_and_nano_launch_arguments"
                    )
                }
                let environment = ProcessInfo.processInfo.environment
                let baseURL = environment["NANO_TTS_BASE_URL"].flatMap(URL.init(string:))
                    ?? JarvisBridgeRuntime.baseURL
                let voice = environment["NANO_TTS_VOICE"]
                    ?? NanoRemoteTTSConfiguration.defaultVoice
                let language = environment["NANO_TTS_LANGUAGE"]
                    ?? NanoRemoteTTSConfiguration.defaultLanguage
                let steps = environment["NANO_TTS_STEPS"].flatMap(Int.init)
                    ?? NanoRemoteTTSConfiguration.defaultSteps
                let configuration = try NanoRemoteTTSConfiguration(
                    baseURL: baseURL,
                    voice: voice,
                    language: language,
                    steps: steps
                )
                nanoTTS = JarvisVoiceNanoRemoteSpeechOutput(
                    audio: audio,
                    configuration: configuration
                )
                nanoTTSConfigurationError = nil
            } catch {
                nanoTTS = nil
                nanoTTSConfigurationError = error.localizedDescription
            }
        } else {
            nanoTTS = nil
            nanoTTSConfigurationError = nil
        }
        super.init()
        if routeMode == .adaptiveJarvis {
            audioRouteCancellable = NotificationCenter.default.publisher(
                for: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                Task { @MainActor in
                    self?.handleAdaptiveAudioRouteChange(notification)
                }
            }
        }
        if nanoTTSModeEnabled {
            ttsStatus = nanoTTS == nil
                ? "Nano remote unavailable"
                : "Nano remote ready"
        }
        conversation = conversationStore.load()
        speechInput.delegate = self
        jarvisStatus = initialBrainMode == .codexBridge
            ? "Codex bridge selected"
            : "Local Gemma selected"
        if experimentalSemanticRouterEnabled {
            switch semanticRouter.availability {
            case .ready: semanticRouterStatus = "EmbeddingGemma experimental runtime deferred"
            case let .unavailable(reason): semanticRouterStatus = reason
            }
        } else {
            semanticRouterStatus = "EmbeddingGemma experimental lane disabled"
        }
        Task { [weak self] in
            self?.brainStatus = await self?.brain.availability() ?? "gemma_e2b_model_missing"
        }
        jarvisInboxTask = Task { [weak self] in
            await self?.monitorJarvisInbox()
        }
        ledger.record(
            experimentalSemanticRouterEnabled ? "semantic_router_deferred" : "semantic_router_disabled",
            fields: [
                "reason": experimentalSemanticRouterEnabled
                    ? "keep_voice_startup_model_loads_serial"
                    : "unvalidated_advisory_router_excluded_from_golden_recovery",
                "model": "EmbeddingGemma-300M_seq256",
                "runtime": "TensorFlowLiteSwift",
                "backend": "cpu_xnnpack",
                "enabled": String(experimentalSemanticRouterEnabled)
            ]
        )
        ledger.record("run_started", fields: [
            "app": "Jarvis",
            "router": semanticRouterStatus,
            "brain_mode": initialBrainMode.rawValue,
            "brain": initialBrainMode.brainImplementation,
            "brain_model": initialBrainMode.brainModel,
            "brain_runtime": initialBrainMode.brainRuntime,
            "jarvis_bridge_base_url": JarvisBridgeRuntime.baseURL.absoluteString,
            "stt": "parakeet_eou_120m_coreml_160ms",
            "vad": "silero_coreml_shared_capture",
            "tts": nanoTTSModeEnabled
                ? "supertonic_nano_remote"
                : "supertonic_3_coreml_shared_voice_processing_graph",
            "tts_fallback_allowed": "false",
            "nano_tts_configuration": nanoTTSModeEnabled
                ? (nanoTTS == nil ? "invalid" : "ready")
                : "disabled",
            "audio_graph": routeMode == .adaptiveJarvis
                ? "single_av_audio_engine_adaptive_bose_meta_iphone"
                : routeMode == .callFreeJarvis
                    ? "single_av_audio_engine_iphone_mic_a2dp_or_speaker"
                    : "single_av_audio_engine_voice_processing_enabled",
            "audio_route_priority": routeMode == .adaptiveJarvis
                ? "bose_then_meta_glasses_then_iphone"
                : routeMode == .callFreeJarvis
                    ? "a2dp_output_then_iphone_speaker_with_iphone_mic"
                    : "iphone",
            "audio_session_profile": audioLaunchSelection.profile.rawValue,
            "hfp_microphone_authorized": String(
                audioLaunchSelection.hfpMicrophoneAuthorized
            ),
            "audio_session_policy_reason": audioLaunchSelection.reason
        ])
        ledger.recordBuildProvenance()
        Task { [weak self] in
            guard let self else { return }
            await self.jarvis.setEnabled(initialBrainMode == .codexBridge)
        }
    }

    func toggleListening() {
        if speechInput.isRunning {
            stopListening()
        } else {
            startListening()
        }
    }

    func reportUIAppeared() {
        let fields = [
            "conversation_count": String(conversation.count),
            "visible_group_limit": "40",
            "render_mode": "lazy_top_first"
        ]
        ledger.record("ui_appeared", fields: fields)
        Task {
            await jarvis.report(event: "phone_ui_appeared", fields: fields)
        }
    }

    func runSemanticRouterProbe() {
        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            let warmStatus = await self.semanticRouter.warm()
            let warmElapsedMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            let regressionCases = [
                ("How has your day been?", "none"),
                ("Help me think through this architecture.", "none"),
                ("What is the capital of France?", "none"),
                ("Yes, make sure it is all local.", "none"),
                ("Interesting, it seems to be working but I cannot really tell.", "none"),
                ("Which one? Yeah.", "none"),
                ("Actually, plastic. Let's do plastic.", "none"),
                ("That is a good point.", "none"),
                ("Tell me about Kokoro's architecture.", "none"),
                ("Center on the floor of patches more but that is painting problem.", "none"),
                ("Stop speaking and listen to me.", "stop"),
                ("Pause your answer right now.", "stop"),
                ("Cancel that response.", "stop"),
                ("I just manually paused your response.", "stop"),
                ("What did I ask you before this?", "memory"),
                ("Remember that I prefer concise answers.", "memory"),
                ("Recall our earlier conversation.", "memory"),
                ("Do you remember talking about Hopkinton?", "memory"),
                ("Did you read what I said before?", "memory"),
                ("Why is the microphone not hearing me?", "voice_diagnostics"),
                ("Check the speech recognition latency.", "voice_diagnostics"),
                ("Is Kokoro playing through the correct audio route?", "voice_diagnostics"),
                ("Where are we on latency? What are the metrics?", "voice_diagnostics"),
                ("Is text to speech warm and kept loaded?", "voice_diagnostics"),
                ("My speech got cut off before it finalized.", "voice_diagnostics"),
                ("Barge in was not working when I kept saying stop.", "voice_diagnostics"),
                ("Text generated but I never heard the response.", "voice_diagnostics"),
                ("I still hear I am pronounced as yam.", "voice_diagnostics"),
                ("The microphone keeps buzzing on and off.", "voice_diagnostics")
            ]
            let holdoutCases = [
                ("Could you explain why the sky changes color at sunset?", "none"),
                ("I think the smaller model may be enough.", "none"),
                ("What should we build next?", "none"),
                ("That sounded much better than before.", "none"),
                ("I am heading out for dinner.", "none"),
                ("Tell me why speech recognition is difficult in noisy rooms.", "none"),
                ("Write a story about a microphone that became self-aware.", "none"),
                ("Stop signs are red for visibility.", "none"),
                ("Pause is a useful control in media apps.", "none"),
                ("The microphone on the new phone is impressive.", "none"),
                ("Kokoro is a Japanese word.", "none"),
                ("Why does barge in matter in conversational AI?", "none"),
                ("Hold on, let me finish.", "stop"),
                ("Enough, listen to me now.", "stop"),
                ("Do not continue that answer.", "stop"),
                ("Save this for tomorrow: test outside.", "memory"),
                ("What was the town I mentioned while running errands?", "memory"),
                ("Have we discussed pronunciation already?", "memory"),
                ("Your voice went quiet halfway through.", "voice_diagnostics"),
                ("Why did it take fifteen seconds to answer?", "voice_diagnostics"),
                ("You are transcribing the television instead of me.", "voice_diagnostics"),
                ("The reply is visible but silent.", "voice_diagnostics"),
                ("Can you hear me over the meeting?", "voice_diagnostics"),
                ("It keeps listening to its own voice.", "voice_diagnostics")
            ]
            let cases = regressionCases.map { ($0.0, $0.1, "regression") }
                + holdoutCases.map { ($0.0, $0.1, "holdout") }
            var passed = 0
            var regressionPassed = 0
            var holdoutPassed = 0
            var routeLatencyTotal = 0
            var routeLatencyMaximum = 0
            for (transcript, expectedRoute, corpus) in cases {
                let routeStarted = Date()
                let decision = await self.semanticRouter.route(finalTranscript: transcript)
                let routeElapsed = Int(Date().timeIntervalSince(routeStarted) * 1_000)
                let probeDecision = await self.semanticRouter.probeDecision(finalTranscript: transcript)
                routeLatencyTotal += routeElapsed
                routeLatencyMaximum = max(routeLatencyMaximum, routeElapsed)
                let actualRoute = decision?.route ?? "none"
                let didPass = actualRoute == expectedRoute
                if didPass {
                    passed += 1
                    if corpus == "regression" {
                        regressionPassed += 1
                    } else {
                        holdoutPassed += 1
                    }
                }
                self.ledger.record("semantic_router_probe_case", fields: [
                    "corpus": corpus,
                    "transcript": transcript,
                    "expected_route": expectedRoute,
                    "actual_route": actualRoute,
                    "confidence": decision.map { String($0.confidence) } ?? "none",
                    "best_route": probeDecision?.route ?? "none",
                    "best_confidence": probeDecision.map { String($0.confidence) } ?? "none",
                    "elapsed_ms": String(routeElapsed),
                    "passed": String(didPass)
                ])
            }
            let averageRouteMilliseconds = cases.isEmpty ? -1 : routeLatencyTotal / cases.count
            let fields = [
                "status": warmStatus,
                "warm_elapsed_ms": String(warmElapsedMilliseconds),
                "cases": String(cases.count),
                "passed": String(passed),
                "regression_cases": String(regressionCases.count),
                "regression_passed": String(regressionPassed),
                "holdout_cases": String(holdoutCases.count),
                "holdout_passed": String(holdoutPassed),
                "average_route_ms": String(averageRouteMilliseconds),
                "maximum_route_ms": String(routeLatencyMaximum)
            ]
            self.semanticRouterStatus = warmStatus
            self.ledger.record("semantic_router_probe", fields: fields)
            print("ARTEMIS_SEMANTIC_ROUTER_PROBE \(fields)")
        }
    }

    func startListening() {
        guard !speechInput.isRunning, startupTask == nil else { return }
        if experimentalSemanticRouterEnabled,
           case let .unavailable(reason) = semanticRouter.availability {
            phase = .unavailable(reason)
            ledger.record("semantic_router_live_start_denied", fields: [
                "reason": reason,
                "fallback_triggered": "false",
                "fallback_reason": "experimental_router_unavailable"
            ])
            return
        }
        phase = .starting
        microphoneReady = false
        sileroVADReady = false
        ledger.record("speech_start_requested")
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startupTask = nil }
            do {
                let state = try await speechInput.start()
                guard !Task.isCancelled else {
                    speechInput.stop()
                    return
                }
                microphoneReady = true
                recognizerProven = false
                consecutiveMeaningfulSegmentsWithoutTranscript = 0
                phase = .listening
                ledger.record("speech_started", fields: [
                    "stt_source": "parakeet_eou_120m_coreml_160ms",
                    "vad": "silero_coreml_shared_capture",
                    "audio_graph": state.voiceProcessingEnabled
                        ? "single_av_audio_engine_voice_processing_enabled"
                        : "single_av_audio_engine_iphone_mic_meta_a2dp",
                    "voice_processing_enabled": String(state.voiceProcessingEnabled),
                    "route": state.routeDescription,
                    "sample_rate": String(state.sampleRate),
                    "output_latency_ms": String(Int(state.outputLatency * 1_000))
                ])
                await jarvis.report(event: "phone_speech_started", fields: [
                    "route": state.routeDescription,
                    "sample_rate": String(state.sampleRate),
                    "output_latency_ms": String(Int(state.outputLatency * 1_000))
                ])
                warmBrainIfNeeded()
            } catch {
                microphoneReady = false
                phase = .unavailable(error.localizedDescription)
                ledger.record("speech_start_failed", fields: ["error": error.localizedDescription])
            }
        }
    }

    func stopListening() {
        startupTask?.cancel()
        startupTask = nil
        brainTask?.cancel()
        brainTask = nil
        Task { await brain.cancelCurrentResponse(reason: "listening_stopped") }
        speechRecoveryTask?.cancel()
        speechRecoveryTask = nil
        adaptiveRouteRecoveryTask?.cancel()
        adaptiveRouteRecoveryTask = nil
        adaptiveRouteRecoveryPending = false
        semanticRouterWarmTask?.cancel()
        semanticRouterWarmTask = nil
        endpointTask?.cancel()
        endpointTask = nil
        speechInput.stop()
        microphoneReady = false
        recognizerProven = false
        sileroVADReady = false
        consecutiveMeaningfulSegmentsWithoutTranscript = 0
        phase = .idle
        ledger.record("speech_stopped")
    }

    private func handleAdaptiveAudioRouteChange(_ notification: Notification) {
        guard audio.usesAdaptiveRouting else { return }
        let evaluation = audio.adaptiveRouteEvaluation()
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let fields = [
            "reason_raw": reasonValue.map(String.init) ?? "unknown",
            "desired_target": evaluation.desired.target.rawValue,
            "current_output_target": evaluation.currentOutputTarget.rawValue,
            "requires_reconfiguration": String(evaluation.requiresReconfiguration),
            "selection_reason": evaluation.desired.reason,
            "route": audio.state().routeDescription,
            "tts_in_flight": String(ttsIsSpeaking)
        ]
        ledger.record("adaptive_audio_route_changed", fields: fields)
        Task { await jarvis.report(event: "phone_adaptive_audio_route_changed", fields: fields) }

        guard evaluation.requiresReconfiguration, microphoneReady else { return }
        if ttsIsSpeaking {
            adaptiveRouteRecoveryPending = true
            ledger.record("adaptive_audio_route_recovery_deferred", fields: fields)
            return
        }
        scheduleAdaptiveAudioRouteRecovery(trigger: "route_change")
    }

    private func scheduleAdaptiveAudioRouteRecovery(trigger: String) {
        guard audio.usesAdaptiveRouting,
              microphoneReady,
              adaptiveRouteRecoveryTask == nil else { return }
        adaptiveRouteRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.adaptiveRouteRecoveryTask = nil }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let evaluation = self.audio.adaptiveRouteEvaluation()
            guard evaluation.requiresReconfiguration else {
                self.adaptiveRouteRecoveryPending = false
                return
            }
            self.adaptiveRouteRecoveryPending = false
            self.ledger.record("adaptive_audio_route_recovery_requested", fields: [
                "trigger": trigger,
                "desired_target": evaluation.desired.target.rawValue,
                "current_output_target": evaluation.currentOutputTarget.rawValue,
                "selection_reason": evaluation.desired.reason
            ])
            self.recoverSpeechCapture(trigger: "adaptive_audio_\(trigger)", forceRestart: true)
        }
    }

    private func warmBrainIfNeeded() {
        if jarvisModeEnabled {
            brainStatus = "Codex manager bridge"
            ledger.record("brain_warm_skipped", fields: [
                "reason": "jarvis_codex_bridge_mode",
                "brain_impl": "codex_manager_proxy",
                "brain_model": "codex_low_latency_proxy",
                "brain_runtime": "m4_jarvis_bridge",
                "model_api_calls": "false"
            ])
            warmTTSIfNeeded()
            return
        }
        guard brainWarmTask == nil else { return }
        brainStatus = "Warming Gemma E2B"
        brainWarmTask = Task { [weak self] in
            guard let self else { return }
            defer { self.brainWarmTask = nil }
            do {
                let warmedModel = try await self.brain.warm(memoryContext: self.durableMemoryContext())
                self.brainStatus = "Gemma E2B ready"
                let microphoneActive = self.speechInput.isRunning
                self.ledger.record("brain_warm", fields: [
                    "brain_impl": "gemma_e2b_litertlm",
                    "brain_model": warmedModel,
                    "brain_runtime": "litert_lm_gpu",
                    "status": "ready",
                    "microphone_active_during_warm": String(microphoneActive)
                ])
                if !microphoneActive {
                    self.recoverSpeechCapture(trigger: "brain_warm", forceRestart: false)
                }
            } catch {
                self.brainStatus = error.localizedDescription
                self.ledger.record("brain_warm", fields: [
                    "brain_impl": "gemma_e2b_litertlm",
                    "brain_runtime": "litert_lm_gpu",
                    "status": "failed",
                    "error": error.localizedDescription
                ])
            }
            guard !Task.isCancelled else { return }
            self.warmTTSIfNeeded()
        }
    }

    private func recoverSpeechCapture(trigger: String, forceRestart: Bool) {
        guard microphoneReady,
              (forceRestart || !speechInput.isRunning),
              speechRecoveryTask == nil else { return }

        microphoneReady = false
        phase = .starting
        ledger.record("speech_capture_recovery_started", fields: [
            "trigger": trigger,
            "reason": forceRestart
                ? "asr_unhealthy_despite_active_audio_engine"
                : "audio_engine_inactive_after_model_warmup"
        ])

        speechRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.speechRecoveryTask = nil }
            do {
                let state = try await self.speechInput.restart()
                guard !Task.isCancelled else {
                    self.speechInput.stop()
                    return
                }
                self.microphoneReady = true
                self.recognizerProven = false
                self.consecutiveMeaningfulSegmentsWithoutTranscript = 0
                self.phase = .listening
                self.ledger.record("speech_capture_recovered", fields: [
                    "trigger": trigger,
                    "route": state.routeDescription,
                    "sample_rate": String(state.sampleRate),
                    "output_latency_ms": String(Int(state.outputLatency * 1_000)),
                    "audio_engine_running": String(state.engineRunning)
                ])
                self.scheduleSemanticRouterWarmIfIdle()
            } catch {
                guard !Task.isCancelled else { return }
                self.microphoneReady = false
                self.recognizerProven = false
                self.phase = .unavailable(error.localizedDescription)
                self.ledger.record("speech_capture_recovery_failed", fields: [
                    "trigger": trigger,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func warmTTSIfNeeded() {
        guard !ttsWarmProbeStarted else { return }
        ttsWarmProbeStarted = true
        if nanoTTSModeEnabled {
            ttsWarmProbeFinished = nanoTTS != nil
            ledger.record("tts_warm_probe", fields: [
                "status": nanoTTS == nil ? "configuration_failed" : "remote_deferred_until_first_chunk",
                "tts_engine": "supertonic_nano_remote",
                "fallback_triggered": "false",
                "fallback_reason": "none",
                "error": nanoTTSConfigurationError ?? "none"
            ])
            return
        }
        let started = Date()
        tts.generateOnly("Ready") { [weak self] result in
            guard let self else { return }
            self.ttsWarmProbeFinished = true
            switch result {
            case let .success(stats):
                let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
                self.ledger.record("tts_warm_probe", fields: [
                    "status": "ready",
                    "elapsed_ms": String(elapsed),
                    "generation_ms": String(stats.generationMilliseconds),
                    "tts_engine": stats.engineID,
                    "voice": stats.voiceName,
                    "normalized_text": stats.normalizedText,
                    "seed_policy": stats.seedPolicy,
                    "runtime_revision": stats.runtimeRevision,
                    "model_manifest_sha256": stats.modelManifestSHA256,
                    "voice_style_sha256": stats.voiceStyleSHA256,
                    "thermal_state": stats.thermalState
                ])
                Task {
                    await self.jarvis.report(event: "phone_tts_warm_ready", fields: [
                        "elapsed_ms": String(elapsed),
                        "generation_ms": String(stats.generationMilliseconds),
                        "tts_engine": stats.engineID,
                        "voice": stats.voiceName,
                        "normalized_text": stats.normalizedText,
                        "runtime_revision": stats.runtimeRevision,
                        "thermal_state": stats.thermalState
                    ])
                }
            case let .failure(error):
                self.ledger.record("tts_warm_probe", fields: [
                    "status": "failed",
                    "error": error.localizedDescription
                ])
                Task {
                    await self.jarvis.report(event: "phone_tts_warm_failed", fields: [
                        "error": error.localizedDescription
                    ])
                }
            }
            self.scheduleSemanticRouterWarmIfIdle()
        }
    }

    private func scheduleSemanticRouterWarmIfIdle() {
        guard experimentalSemanticRouterEnabled,
              ttsWarmProbeFinished,
              !semanticRouterWarmed,
              semanticRouterWarmTask == nil else { return }
        semanticRouterWarmTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                self.semanticRouterWarmTask = nil
                return
            }
            guard !Task.isCancelled,
                  self.speechInput.isRunning,
                  self.phase == .listening,
                  !self.vadSpeechActive,
                  !self.ttsIsSpeaking,
                  self.brainTask == nil else {
                self.semanticRouterWarmTask = nil
                return
            }
            let started = Date()
            let status = await self.semanticRouter.warm()
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            self.semanticRouterStatus = status
            self.semanticRouterWarmed = status == "embeddinggemma_ready_cpu_xnnpack"
            self.ledger.record("semantic_router_warm", fields: [
                "status": status,
                "elapsed_ms": String(elapsed),
                "policy": "idle_after_gemma_and_kokoro_warm"
            ])
            self.semanticRouterWarmTask = nil
        }
    }

    func submitTypedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        acceptFinalTranscript(trimmed, source: "typed", finalizationReason: "typed_submit")
    }

    func configureVisualContextProvider(
        _ provider: @escaping (
            String,
            UUID,
            JarvisVisualIntentDecision
        ) async throws -> JarvisVisualEvidence?
    ) {
        visualContextProvider = provider
        ledger.record("visual_context_provider_configured", fields: [
            "provider": "meta_dat_lfm450m",
            "authority": "evidence_only"
        ])
    }

    @discardableResult
    func selectBrainMode(_ mode: JarvisBrainMode) -> Bool {
        guard mode != brainMode else { return true }
        if nanoTTSModeEnabled, mode != .codexBridge {
            ledger.record("brain_mode_change_denied", fields: [
                "requested_mode": mode.rawValue,
                "reason": "nano_tts_requires_codex_bridge"
            ])
            return false
        }
        guard !ttsIsSpeaking,
              brainTask == nil,
              currentJarvisRequestID == nil,
              activeJarvisStreamRequestID == nil else {
            ledger.record("brain_mode_change_denied", fields: [
                "requested_mode": mode.rawValue,
                "reason": "turn_or_playback_active"
            ])
            return false
        }

        jarvisTask?.cancel()
        jarvisTask = nil
        brainMode = mode
        jarvisStatus = mode == .codexBridge
            ? "Checking Codex bridge"
            : "Local Gemma selected"
        ledger.record("brain_mode_changed", fields: [
            "mode": mode.rawValue,
            "brain_impl": mode.brainImplementation,
            "brain_model": mode.brainModel,
            "brain_runtime": mode.brainRuntime
        ])
        Task { [weak self] in
            guard let self else { return }
            await self.jarvis.setEnabled(mode == .codexBridge)
            if mode == .codexBridge {
                self.jarvisStatus = await self.jarvis.health()
                    ? "Codex bridge connected"
                    : "Codex bridge unavailable"
            } else if self.microphoneReady {
                self.warmBrainIfNeeded()
            }
        }
        return true
    }

    func toggleJarvisMode() {
        _ = selectBrainMode(jarvisModeEnabled ? .localGemma : .codexBridge)
    }

    private func monitorJarvisInbox() async {
        while !Task.isCancelled {
            if jarvisModeEnabled, speechInput.isRunning, !vadSpeechActive {
                do {
                    if let requestID = currentJarvisRequestID ?? activeJarvisStreamRequestID {
                        try await fetchJarvisInbox(
                            acceptingRequestID: requestID,
                            maxBatches: 8
                        )
                    } else {
                        try await fetchSpecialChannelInbox(maxBatches: 8)
                    }
                } catch {
                    // Health polling owns visible availability state; inbox retries quietly.
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func fetchSpecialChannelInbox(maxBatches: Int) async throws {
        for _ in 0..<maxBatches {
            let messages = try await jarvis.inbox(after: latestJarvisMessageID)
            guard let newest = messages.last else { return }
            latestJarvisMessageID = newest.id
            UserDefaults.standard.set(
                String(newest.id),
                forKey: "jarvis.latestInboundMessageID"
            )
            let accepted = messages.filter { JarvisSpecialChannelPolicy.accepts($0) }
            pendingJarvisInboundMessages.append(contentsOf: accepted)
            ledger.record("special_channel_inbox_fetched", fields: [
                "fetched_count": String(messages.count),
                "accepted_count": String(accepted.count),
                "latest_message_id": String(newest.id)
            ])
            drainJarvisInboundMessages()
            if !accepted.isEmpty || messages.count < 8 {
                return
            }
        }
        ledger.record("special_channel_inbox_backlog_limit", fields: [
            "max_batches": String(maxBatches)
        ])
    }

    private func fetchJarvisInbox(
        acceptingRequestID requestID: String,
        maxBatches: Int
    ) async throws {
        for _ in 0..<maxBatches {
            let batch = try await fetchJarvisInboxOnce(acceptingRequestID: requestID)
            if batch.accepted > 0 || batch.fetched == 0 {
                return
            }
        }
        ledger.record("jarvis_inbox_backlog_limit", fields: [
            "request_id": requestID,
            "max_batches": String(maxBatches)
        ])
    }

    private func fetchJarvisInboxOnce(
        acceptingRequestID requestID: String
    ) async throws -> (fetched: Int, accepted: Int) {
        let messages = try await jarvis.inbox(after: latestJarvisMessageID)
        guard let newest = messages.last else { return (0, 0) }
        latestJarvisMessageID = newest.id
        UserDefaults.standard.set(
            String(newest.id),
            forKey: "jarvis.latestInboundMessageID"
        )
        let accepted = messages.filter { message in
            message.requestID == requestID
                && !discardedJarvisRequestIDs.contains(requestID)
        }
        pendingJarvisInboundMessages.append(contentsOf: accepted)
        ledger.record("jarvis_inbox_fetched", fields: [
            "request_id": requestID,
            "fetched_count": String(messages.count),
            "accepted_count": String(accepted.count),
            "latest_message_id": String(newest.id)
        ])
        drainJarvisInboundMessages()
        return (messages.count, accepted.count)
    }

    private func drainJarvisInboundMessages() {
        guard !vadSpeechActive else { return }

        if let requestID = activeJarvisStreamRequestID {
            let matching = takePendingJarvisMessages(requestID: requestID)
            appendJarvisStreamMessages(matching)
            finishJarvisStreamIfComplete(requestID: requestID)
            return
        }

        guard !ttsIsSpeaking, let first = pendingJarvisInboundMessages.first else { return }
        if first.source == "jarvis_stream", let requestID = first.requestID {
            let matching = takePendingJarvisMessages(requestID: requestID)
            beginJarvisStream(requestID: requestID)
            appendJarvisStreamMessages(matching)
            finishJarvisStreamIfComplete(requestID: requestID)
            return
        }

        pendingJarvisInboundMessages.removeFirst()
        speakStandaloneJarvisMessage(first)
    }

    private func takePendingJarvisMessages(requestID: String) -> [JarvisInboundMessage] {
        let matching = pendingJarvisInboundMessages
            .filter { $0.requestID == requestID }
            .sorted { lhs, rhs in
                let left = lhs.sequence ?? Int.max
                let right = rhs.sequence ?? Int.max
                return left == right ? lhs.id < rhs.id : left < right
            }
        pendingJarvisInboundMessages.removeAll { $0.requestID == requestID }
        return matching
    }

    private func speakStandaloneJarvisMessage(_ message: JarvisInboundMessage) {
        turnGeneration += 1
        let generation = turnGeneration
        let turnID = UUID()
        activeTurnID = turnID
        activeTurnStartedAt = Date(timeIntervalSince1970: message.createdAt)
        firstBrainFragmentAt = Date()
        conversation.append(ConversationLine(role: .assistant, text: message.text, state: .complete))
        persistConversation()
        ledger.record("jarvis_inbound_received", fields: [
            "turn_id": turnID.uuidString,
            "message_id": String(message.id),
            "source": message.source,
            "text": message.text
        ])
        Task {
            await jarvis.report(event: "phone_inbound_received", fields: [
                "turn_id": turnID.uuidString,
                "message_id": String(message.id)
            ])
        }
        speakResponse(message.text, turnID: turnID, generation: generation)
    }

    private func beginJarvisStream(requestID: String) {
        guard activeJarvisStreamRequestID == nil else { return }
        let turnID = activeTurnID ?? UUID()
        let generation = turnGeneration
        activeTurnID = turnID
        activeJarvisStreamRequestID = requestID
        activeJarvisStreamTurnID = turnID
        activeJarvisStreamGeneration = generation
        activeJarvisStreamReceivedSequences = []
        activeJarvisConversationLineIndex = nil
        firstBrainFragmentAt = firstBrainFragmentAt ?? Date()
        ttsIsSpeaking = true
        pendingBargeIn = false
        bargeInCandidateStartedAt = nil
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        activeAssistantResponse = ""
        phase = .responding
        let ttsEngine = nanoTTSModeEnabled
            ? "supertonic_nano_remote"
            : "supertonic_3_coreml"
        ttsStatus = nanoTTSModeEnabled ? "Nano remote streaming" : "Supertonic streaming"
        ledger.record("tts_stream_started", fields: [
            "turn_id": turnID.uuidString,
            "request_id": requestID,
            "tts_engine": ttsEngine,
            "route": audio.state().routeDescription,
            "audio_graph": "shared_voice_processing_engine",
            "fallback_triggered": "false",
            "fallback_reason": "none"
        ])
        armVoiceProcessingBargeIn(turnID: turnID, generation: generation)
        Task {
            await jarvis.report(event: "phone_tts_stream_started", fields: [
                "turn_id": turnID.uuidString,
                "request_id": requestID,
                "route": audio.state().routeDescription
            ])
        }

        if nanoTTSModeEnabled {
            guard let nanoTTS else {
                completeNanoJarvisStreamPlayback(
                    .failure(JarvisVoiceNanoRemoteSpeechOutputError.invalidConfiguration(
                        nanoTTSConfigurationError ?? "missing_client"
                    )),
                    requestID: requestID,
                    turnID: turnID,
                    generation: generation
                )
                return
            }
            activeJarvisStreamSessionID = nanoTTS.beginStreaming(
                onChunkGenerated: { [weak self] index, total, stats in
                    guard let self,
                          self.activeJarvisStreamRequestID == requestID,
                          self.activeJarvisStreamGeneration == generation else { return }
                    self.ttsStatus = "Nano remote streaming \(index + 1)/\(total)"
                    var fields = stats.telemetryFields
                    fields["turn_id"] = turnID.uuidString
                    fields["request_id"] = requestID
                    fields["index"] = String(index)
                    fields["known_total"] = String(total)
                    self.ledger.record("tts_stream_chunk_generated", fields: fields)
                    Task {
                        await self.jarvis.report(
                            event: "phone_tts_stream_chunk_generated",
                            fields: fields
                        )
                    }
                },
                onPipelineState: { [weak self] snapshot in
                    self?.recordTTSPipelineState(
                        snapshot,
                        turnID: turnID,
                        requestID: requestID,
                        source: "jarvis_proxy_nano_remote"
                    )
                },
                completion: { [weak self] result in
                    self?.completeNanoJarvisStreamPlayback(
                        result,
                        requestID: requestID,
                        turnID: turnID,
                        generation: generation
                    )
                }
            )
            return
        }

        activeJarvisStreamSessionID = tts.beginStreaming(
            onChunkGenerated: { [weak self] index, total, chunk, stats in
                guard let self,
                      self.activeJarvisStreamRequestID == requestID,
                      self.activeJarvisStreamGeneration == generation else { return }
                self.ttsStatus = "Supertonic streaming \(index + 1)/\(total)"
                self.ledger.record("tts_stream_chunk_generated", fields: [
                    "turn_id": turnID.uuidString,
                    "request_id": requestID,
                    "index": String(index),
                    "known_total": String(total),
                    "text": chunk,
                    "generation_ms": String(stats.generationMilliseconds),
                    "audio_seconds": String(stats.audioDurationSeconds),
                    "tts_engine": stats.engineID,
                    "voice": stats.voiceName,
                    "normalized_text": stats.normalizedText,
                    "seed": String(stats.seed),
                    "seed_policy": stats.seedPolicy,
                    "runtime_revision": stats.runtimeRevision,
                    "real_time_factor": String(stats.realTimeFactor),
                    "route": stats.audioRoute,
                    "playback_state": stats.playbackState,
                    "lifecycle_epoch": String(stats.lifecycleEpoch)
                ])
                Task {
                    await self.jarvis.report(event: "phone_tts_stream_chunk_generated", fields: [
                        "turn_id": turnID.uuidString,
                        "request_id": requestID,
                        "index": String(index),
                        "generation_ms": String(stats.generationMilliseconds),
                        "tts_engine": stats.engineID,
                        "voice": stats.voiceName,
                        "normalized_text": stats.normalizedText,
                        "runtime_revision": stats.runtimeRevision,
                        "route": stats.audioRoute
                    ])
                }
            },
            onPipelineState: { [weak self] snapshot in
                self?.recordTTSPipelineState(
                    snapshot,
                    turnID: turnID,
                    requestID: requestID,
                    source: "jarvis_proxy"
                )
            },
            completion: { [weak self] result in
                self?.completeJarvisStreamPlayback(
                    result,
                    requestID: requestID,
                    turnID: turnID,
                    generation: generation
                )
            }
        )
    }

    private func appendJarvisStreamMessages(_ messages: [JarvisInboundMessage]) {
        guard let requestID = activeJarvisStreamRequestID,
              let sessionID = activeJarvisStreamSessionID,
              !messages.isEmpty else { return }

        for message in messages {
            guard message.requestID == requestID else { continue }
            if let sequence = message.sequence {
                guard activeJarvisStreamReceivedSequences.insert(sequence).inserted else { continue }
            }

            let joined = activeAssistantResponse.isEmpty
                ? message.text
                : "\(activeAssistantResponse) \(message.text)"
            activeAssistantResponse = joined
            if let index = activeJarvisConversationLineIndex,
               conversation.indices.contains(index) {
                conversation[index] = ConversationLine(
                    id: conversation[index].id,
                    role: .assistant,
                    text: joined,
                    state: .live
                )
            } else {
                conversation.append(ConversationLine(role: .assistant, text: joined, state: .live))
                activeJarvisConversationLineIndex = conversation.indices.last
            }
            persistConversation()

            ledger.record("jarvis_inbound_received", fields: [
                "turn_id": activeJarvisStreamTurnID?.uuidString ?? "unknown",
                "message_id": String(message.id),
                "request_id": requestID,
                "sequence": String(message.sequence ?? -1),
                "source": message.source,
                "text": message.text
            ])
            Task {
                await jarvis.report(event: "phone_inbound_received", fields: [
                    "turn_id": activeJarvisStreamTurnID?.uuidString ?? "unknown",
                    "message_id": String(message.id),
                    "request_id": requestID,
                    "sequence": String(message.sequence ?? -1)
                ])
            }
            if nanoTTSModeEnabled {
                let chunks = JarvisVoiceTTSChunker.chunks(for: message.text)
                nanoTTS?.appendStreaming(chunks, sessionID: sessionID)
            } else {
                let chunks = ArtemisTTSChunker.chunks(for: message.text)
                tts.appendStreaming(chunks, sessionID: sessionID)
            }
        }
    }

    private func finishJarvisStreamIfComplete(requestID: String) {
        guard activeJarvisStreamRequestID == requestID,
              let sessionID = activeJarvisStreamSessionID,
              let expectedCount = completedJarvisRequestCounts[requestID],
              activeJarvisStreamReceivedSequences.count >= expectedCount else { return }
        completedJarvisRequestCounts.removeValue(forKey: requestID)
        if nanoTTSModeEnabled {
            nanoTTS?.finishStreaming(sessionID: sessionID)
        } else {
            tts.finishStreaming(sessionID: sessionID)
        }
    }

    private func completeJarvisStreamPlayback(
        _ result: Result<VoiceSpeechPlaybackStats, Error>,
        requestID: String,
        turnID: UUID,
        generation: Int
    ) {
        guard activeJarvisStreamRequestID == requestID,
              activeJarvisStreamGeneration == generation else { return }

        if let index = activeJarvisConversationLineIndex,
           conversation.indices.contains(index) {
            conversation[index] = ConversationLine(
                id: conversation[index].id,
                role: .assistant,
                text: conversation[index].text,
                state: .complete
            )
            persistConversation()
        }

        ttsIsSpeaking = false
        pendingBargeIn = false
        audio.endPlaybackSpeechActivityDetection()
        bargeInCandidateStartedAt = nil
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        activeAssistantResponse = ""
        currentJarvisRequestID = nil
        activeJarvisStreamRequestID = nil
        activeJarvisStreamSessionID = nil
        activeJarvisStreamTurnID = nil
        activeJarvisStreamReceivedSequences = []
        activeJarvisConversationLineIndex = nil

        switch result {
        case let .success(stats):
            ttsStatus = "Supertonic complete"
            ledger.record("tts_stream_finished", fields: [
                "turn_id": turnID.uuidString,
                "request_id": requestID,
                "tts_engine": stats.engineID,
                "voice": stats.voiceName,
                "runtime_revision": stats.runtimeRevision,
                "end_to_end_ms": String(elapsedMilliseconds(since: activeTurnStartedAt)),
                "route": stats.audioRoute,
                "playback_state": stats.playbackState,
                "lifecycle_epoch": String(stats.lifecycleEpoch),
                "fallback_triggered": "false",
                "fallback_reason": "none"
            ])
            Task {
                await jarvis.report(event: "phone_tts_stream_finished", fields: [
                    "turn_id": turnID.uuidString,
                    "request_id": requestID,
                    "route": stats.audioRoute
                ])
            }
        case let .failure(error):
            ttsStatus = "Supertonic failed"
            ledger.record("tts_stream_failed", fields: [
                "turn_id": turnID.uuidString,
                "request_id": requestID,
                "error": error.localizedDescription
            ])
            Task {
                await jarvis.report(event: "phone_tts_stream_failed", fields: [
                    "turn_id": turnID.uuidString,
                    "request_id": requestID,
                    "error": error.localizedDescription
                ])
            }
        }

        resumeListeningAfterPlayback(turnID: turnID)
        drainJarvisInboundMessages()
    }

    private func completeNanoJarvisStreamPlayback(
        _ result: Result<JarvisVoiceNanoRemotePlaybackStats, Error>,
        requestID: String,
        turnID: UUID,
        generation: Int
    ) {
        guard activeJarvisStreamRequestID == requestID,
              activeJarvisStreamGeneration == generation else { return }

        if let index = activeJarvisConversationLineIndex,
           conversation.indices.contains(index) {
            conversation[index] = ConversationLine(
                id: conversation[index].id,
                role: .assistant,
                text: conversation[index].text,
                state: .complete
            )
            persistConversation()
        }

        ttsIsSpeaking = false
        pendingBargeIn = false
        audio.endPlaybackSpeechActivityDetection()
        bargeInCandidateStartedAt = nil
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        activeAssistantResponse = ""
        currentJarvisRequestID = nil
        activeJarvisStreamRequestID = nil
        activeJarvisStreamSessionID = nil
        activeJarvisStreamTurnID = nil
        activeJarvisStreamReceivedSequences = []
        activeJarvisConversationLineIndex = nil

        switch result {
        case let .success(stats):
            ttsStatus = "Nano remote complete"
            var fields = stats.telemetryFields
            fields["turn_id"] = turnID.uuidString
            fields["request_id"] = requestID
            fields["stt_source"] = "parakeet_eou_120m_coreml_160ms"
            fields["turn_finalization_reason"] = "hybrid_silero_or_parakeet_eou"
            fields["brain_impl"] = "codex_manager_proxy"
            fields["brain_model"] = "codex_low_latency_proxy"
            fields["brain_runtime"] = "m4_jarvis_bridge"
            fields["vision_model"] = "none"
            fields["vision_frame_id"] = "none"
            fields["first_response_ms"] = String(
                elapsedMilliseconds(since: activeTurnStartedAt, endingAt: firstBrainFragmentAt)
            )
            fields["end_to_end_ms"] = String(elapsedMilliseconds(since: activeTurnStartedAt))
            ledger.record("tts_stream_finished", fields: fields)
            Task {
                await jarvis.report(event: "phone_tts_stream_finished", fields: fields)
            }
        case let .failure(error):
            ttsStatus = "Nano remote failed"
            let fields = [
                "turn_id": turnID.uuidString,
                "request_id": requestID,
                "tts_engine": "supertonic_nano_remote",
                "error": error.localizedDescription,
                "fallback_triggered": "false",
                "fallback_reason": "nano_mode_fail_closed"
            ]
            ledger.record("tts_stream_failed", fields: fields)
            Task {
                await jarvis.report(event: "phone_tts_stream_failed", fields: fields)
            }
        }

        resumeListeningAfterPlayback(turnID: turnID)
        drainJarvisInboundMessages()
    }

    private func cancelActiveJarvisRequest(reason: String) {
        guard let requestID = currentJarvisRequestID ?? activeJarvisStreamRequestID else { return }
        discardedJarvisRequestIDs.insert(requestID)
        completedJarvisRequestCounts.removeValue(forKey: requestID)
        pendingJarvisInboundMessages.removeAll { $0.requestID == requestID }
        if activeJarvisStreamRequestID == requestID {
            audio.endPlaybackSpeechActivityDetection()
            stopSelectedTTS()
            if let index = activeJarvisConversationLineIndex,
               conversation.indices.contains(index) {
                conversation[index] = ConversationLine(
                    id: conversation[index].id,
                    role: .assistant,
                    text: conversation[index].text,
                    state: .complete
                )
                persistConversation()
            }
        }
        currentJarvisRequestID = nil
        activeJarvisStreamRequestID = nil
        activeJarvisStreamSessionID = nil
        activeJarvisStreamTurnID = nil
        activeJarvisStreamReceivedSequences = []
        activeJarvisConversationLineIndex = nil
        ttsIsSpeaking = false
        bargeInCandidateStartedAt = nil
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        activeAssistantResponse = ""
        ledger.record("jarvis_request_cancelled", fields: [
            "request_id": requestID,
            "reason": reason
        ])
    }

    private func stopSelectedTTS() {
        if nanoTTSModeEnabled {
            nanoTTS?.stop()
        } else {
            tts.stop()
        }
    }

    func importGemmaModel(from sourceURL: URL) {
        let granted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if granted { sourceURL.stopAccessingSecurityScopedResource() }
        }
        do {
            guard sourceURL.pathExtension.lowercased() == "litertlm" else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = documents.appendingPathComponent("Models", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            Task { [weak self] in
                self?.brainStatus = await self?.brain.availability() ?? "gemma_e2b_model_missing"
            }
            ledger.record("gemma_model_imported", fields: ["filename": destination.lastPathComponent])
        } catch {
            brainStatus = "Gemma import failed: \(error.localizedDescription)"
            ledger.record("gemma_model_import_failed", fields: ["error": error.localizedDescription])
        }
    }

    private func acceptFinalTranscript(
        _ text: String,
        source: String,
        finalizationReason: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, finalizedTranscriptForTurn != trimmed else {
            ledger.record("stt_final_ignored", fields: [
                "reason": trimmed.isEmpty ? "empty" : "duplicate_turn",
                "source": source
            ])
            return
        }
        if !ttsIsSpeaking, isControlOnlyBargeIn(trimmed) {
            finalizedTranscriptForTurn = trimmed
            draftTranscript = ""
            ledger.record("idle_control_consumed", fields: [
                "transcript": trimmed,
                "source": source,
                "policy": "local_reflex_no_brain_turn"
            ])
            Task { await speechInput.resetTranscriptState() }
            phase = speechInput.isRunning ? .listening : .idle
            return
        }
        finalizedTranscriptForTurn = trimmed
        endpointTask?.cancel()
        endpointTask = nil
        cancelActiveJarvisRequest(reason: "new_final_transcript")
        turnGeneration += 1
        let generation = turnGeneration
        let turnID = UUID()
        activeTurnID = turnID
        activeTurnStartedAt = source == "typed" ? Date() : (speechStartedAt ?? Date())
        activeTurnFinalizedAt = Date()
        firstBrainFragmentAt = nil
        activeVisualEvidence = nil
        draftTranscript = ""
        conversation.append(ConversationLine(role: .user, text: trimmed, state: .complete))
        persistConversation()
        let selectedMode = brainMode
        let visualDecision = JarvisVisualIntentPolicy.decide(transcript: trimmed)
        let engineeringIntent = JarvisEngineeringIntentRouterV1.decide(
            transcript: trimmed,
            visualDecision: visualDecision
        )
        ledger.record("stt_final", fields: [
            "turn_id": turnID.uuidString,
            "source": source,
            "stt_source": "parakeet_eou_120m_coreml_160ms",
            "turn_finalization_reason": finalizationReason,
            "transcript": trimmed,
            "brain_mode": selectedMode.rawValue,
            "brain_impl": selectedMode.brainImplementation,
            "brain_model": selectedMode.brainModel,
            "brain_runtime": selectedMode.brainRuntime,
            "vision_intent": visualDecision.action.rawValue,
            "vision_intent_reason": visualDecision.reason,
            "vision_model": visualDecision.requiresVisualContext ? "LFM2.5-VL-450M_pending" : "none",
            "vision_frame_id": visualDecision.requiresVisualContext ? "pending" : "none",
            "tts_engine": nanoTTSModeEnabled
                ? "supertonic_nano_remote"
                : "supertonic_3_coreml",
            "first_response_ms": "pending",
            "end_to_end_ms": "pending",
            "fallback_triggered": "false",
            "fallback_reason": "none"
        ])
        ledger.record("engineering_intent_shadow", fields: [
            "turn_id": turnID.uuidString,
            "schema": JarvisEngineeringIntentRouterV1.schema,
            "route": engineeringIntent.route.rawValue,
            "reason": engineeringIntent.reason,
            "confidence": String(engineeringIntent.confidence),
            "requires_context_machine": String(engineeringIntent.requiresContextMachine),
            "requires_mesh_runtime": String(engineeringIntent.requiresMeshRuntime),
            "requires_camera": String(engineeringIntent.requiresCamera),
            "side_effects_allowed": String(engineeringIntent.sideEffectsAllowed),
            "evidence_source": JarvisEngineeringIntentRouterV1.evidenceSource,
            "stage_1_5_runtime_authority": "unproven"
        ])
        if experimentalSemanticRouterEnabled {
            Task {
                let decision = await semanticRouter.route(finalTranscript: trimmed)
                if let decision {
                    ledger.record("semantic_route", fields: ["route": decision.route, "confidence": String(decision.confidence), "source": decision.source])
                } else {
                    ledger.record("semantic_route_none", fields: ["reason": await semanticRouter.status()])
                }
            }
        } else {
            ledger.record("semantic_route_skipped", fields: [
                "reason": "experimental_router_disabled",
                "turn_id": turnID.uuidString
            ])
        }
        if nanoTTSModeEnabled, !jarvisModeEnabled {
            phase = .unavailable("Nano bridge mode requires the Jarvis bridge.")
            ledger.record("brain_route_denied", fields: [
                "turn_id": turnID.uuidString,
                "brain_impl": "none",
                "tts_engine": "supertonic_nano_remote",
                "reason": "jarvis_bridge_disabled_in_nano_mode",
                "fallback_triggered": "false",
                "fallback_reason": "nano_mode_fail_closed"
            ])
            return
        }
        ledger.record("visual_intent_decision", fields: [
            "turn_id": turnID.uuidString,
            "action": visualDecision.action.rawValue,
            "reason": visualDecision.reason,
            "explicit_user_request": String(visualDecision.explicitUserRequest),
            "camera_side_effect_allowed": String(visualDecision.explicitUserRequest)
        ])
        if selectedMode == .codexBridge {
            jarvisTask?.cancel()
            jarvisTask = Task { [weak self] in
                await self?.prepareAndRunSelectedBrain(
                    for: trimmed,
                    turnID: turnID,
                    generation: generation,
                    selectedMode: selectedMode,
                    visualDecision: visualDecision
                )
            }
        } else {
            brainTask?.cancel()
            brainTask = Task { [weak self] in
                guard let self else { return }
                await self.prepareAndRunSelectedBrain(
                    for: trimmed,
                    turnID: turnID,
                    generation: generation,
                    selectedMode: selectedMode,
                    visualDecision: visualDecision
                )
                if generation == self.turnGeneration {
                    self.brainTask = nil
                }
            }
        }
    }

    private func prepareAndRunSelectedBrain(
        for text: String,
        turnID: UUID,
        generation: Int,
        selectedMode: JarvisBrainMode,
        visualDecision: JarvisVisualIntentDecision
    ) async {
        var visualEvidence: JarvisVisualEvidence?
        if visualDecision.action != .none {
            guard let visualContextProvider else {
                handleVisualContextFailure(
                    JarvisVisualContextError.providerUnavailable,
                    turnID: turnID,
                    generation: generation,
                    decision: visualDecision
                )
                return
            }
            do {
                visualEvidence = try await visualContextProvider(text, turnID, visualDecision)
                guard generation == turnGeneration else { return }
                if visualDecision.requiresVisualContext, visualEvidence == nil {
                    throw JarvisVisualContextError.noFreshFrame("provider_returned_no_evidence")
                }
            } catch {
                guard generation == turnGeneration else { return }
                handleVisualContextFailure(
                    error,
                    turnID: turnID,
                    generation: generation,
                    decision: visualDecision
                )
                return
            }

            if visualDecision.action == .stopCamera {
                let response = "The glasses camera stream is stopped. Voice remains active."
                conversation.append(ConversationLine(role: .assistant, text: response, state: .complete))
                persistConversation()
                ledger.record("camera_control_completed", fields: [
                    "turn_id": turnID.uuidString,
                    "action": visualDecision.action.rawValue,
                    "brain_impl": "deterministic_camera_control",
                    "model_api_calls": "false"
                ])
                speakResponse(response, turnID: turnID, generation: generation)
                return
            }
        }

        if let visualEvidence {
            activeVisualEvidence = visualEvidence
            ledger.record("visual_context_resolved", fields: [
                "turn_id": turnID.uuidString,
                "vision_source": visualEvidence.source,
                "capture_mode": visualEvidence.captureMode,
                "evidence_class": visualEvidence.evidenceClass,
                "vision_model": visualEvidence.model,
                "vision_runtime": visualEvidence.runtime,
                "vision_quantization": visualEvidence.quantization,
                "vision_frame_id": String(visualEvidence.frameID),
                "vision_frame_age_ms": String(visualEvidence.frameAgeMilliseconds),
                "vision_latency_ms": String(visualEvidence.inferenceMilliseconds),
                "vision_confidence": String(visualEvidence.confidence),
                "fallback_triggered": "false",
                "fallback_reason": "none"
            ])
        }

        guard selectedMode == brainMode else {
            ledger.record("brain_result_discarded", fields: [
                "turn_id": turnID.uuidString,
                "reason": "brain_mode_changed"
            ])
            return
        }
        if selectedMode == .codexBridge {
            await runJarvis(
                for: text,
                turnID: turnID,
                generation: generation,
                visualEvidence: visualEvidence
            )
        } else {
            await runBrain(
                for: text,
                turnID: turnID,
                generation: generation,
                visualEvidence: visualEvidence
            )
        }
    }

    private func handleVisualContextFailure(
        _ error: Error,
        turnID: UUID,
        generation: Int,
        decision: JarvisVisualIntentDecision
    ) {
        let detail = error.localizedDescription
        let response = "I can't inspect the glasses view yet. \(detail)"
        phase = .responding
        conversation.append(ConversationLine(role: .assistant, text: response, state: .complete))
        persistConversation()
        ledger.record("visual_context_failed", fields: [
            "turn_id": turnID.uuidString,
            "vision_intent": decision.action.rawValue,
            "vision_model": "LFM2.5-VL-450M",
            "vision_frame_id": "none",
            "error": detail,
            "fallback_triggered": "false",
            "fallback_reason": "visual_request_failed_closed",
            "model_api_calls": "false"
        ])
        speakResponse(response, turnID: turnID, generation: generation)
    }

    private func runJarvis(
        for text: String,
        turnID: UUID,
        generation: Int,
        visualEvidence: JarvisVisualEvidence?
    ) async {
        phase = .responding
        jarvisStatus = "Manager proxy responding"
        let requestID = UUID().uuidString
        currentJarvisRequestID = requestID
        ledger.record("jarvis_request", fields: [
            "turn_id": turnID.uuidString,
            "request_id": requestID,
            "request_text": text
        ])
        var recent = conversation.suffix(10).map { line in
            "\(line.role == .user ? "Devansh" : "Assistant"): \(line.text)"
        }
        if let visualEvidence {
            recent.append(visualEvidence.promptContext)
        }
        do {
            let result = try await jarvis.send(
                requestID: requestID,
                transcript: text,
                recentConversation: recent
            )
            guard !discardedJarvisRequestIDs.contains(result.requestID) else {
                ledger.record("jarvis_result_discarded", fields: [
                    "turn_id": turnID.uuidString,
                    "request_id": result.requestID,
                    "reason": "request_cancelled"
                ])
                return
            }
            guard generation == turnGeneration else {
                ledger.record("jarvis_result_discarded", fields: [
                    "turn_id": turnID.uuidString,
                    "reason": "newer_turn_active"
                ])
                return
            }
            if result.relayPending == true {
                currentJarvisRequestID = nil
                jarvisStatus = "Manager relay connected"
                phase = speechInput.isRunning ? .listening : .idle
                ledger.record("manager_relay_accepted", fields: [
                    "turn_id": turnID.uuidString,
                    "request_id": result.requestID,
                    "elapsed_ms": String(result.elapsedMilliseconds),
                    "fallback_triggered": "false",
                    "fallback_reason": "none"
                ])
                return
            }
            if result.streamed == true {
                let route = result.route?.uppercased() ?? "UNKNOWN"
                jarvisStatus = route == "MANAGER" ? "Manager request queued" : "Manager proxy connected"
                completedJarvisRequestCounts[result.requestID] = result.streamedSentenceCount ?? 0
                ledger.record("jarvis_stream_completed", fields: [
                    "turn_id": turnID.uuidString,
                    "request_id": result.requestID,
                    "elapsed_ms": String(result.elapsedMilliseconds),
                    "sentences": String(result.streamedSentenceCount ?? -1),
                    "route": route
                ])
                do {
                    try await fetchJarvisInbox(
                        acceptingRequestID: result.requestID,
                        maxBatches: 64
                    )
                } catch {
                    ledger.record("jarvis_inbox_fetch_failed", fields: [
                        "turn_id": turnID.uuidString,
                        "request_id": result.requestID,
                        "error": error.localizedDescription
                    ])
                }
                finishJarvisStreamIfComplete(requestID: result.requestID)
                return
            }
            firstBrainFragmentAt = Date()
            jarvisStatus = "Manager proxy connected"
            conversation.append(ConversationLine(role: .assistant, text: result.reply, state: .complete))
            persistConversation()
            ledger.record("jarvis_result", fields: [
                "turn_id": turnID.uuidString,
                "request_id": result.requestID,
                "session_id": result.sessionID ?? "unknown",
                "elapsed_ms": String(result.elapsedMilliseconds),
                "first_response_ms": String(elapsedMilliseconds(since: activeTurnStartedAt)),
                "route": result.route ?? "UNKNOWN",
                "result": result.reply
            ])
            speakResponse(result.reply, turnID: turnID, generation: generation)
        } catch {
            guard generation == turnGeneration else { return }
            currentJarvisRequestID = nil
            jarvisStatus = "Manager proxy unavailable"
            phase = speechInput.isRunning ? .listening : .idle
            conversation.append(ConversationLine(
                role: .assistant,
                text: "Manager proxy failed: \(error.localizedDescription)",
                state: .complete
            ))
            ledger.record("jarvis_failed", fields: [
                "turn_id": turnID.uuidString,
                "error": error.localizedDescription,
                "fallback_triggered": "false",
                "fallback_reason": "jarvis_fail_closed"
            ])
        }
    }

    private func runBrain(
        for text: String,
        turnID: UUID,
        generation: Int,
        visualEvidence: JarvisVisualEvidence?
    ) async {
        phase = .responding
        let started = Date()
        var speechAccumulator = ArtemisTTSStreamAccumulator()
        var speechSessionID: UUID?
        var response = ""
        var responseIndex: Int?
        do {
            var memoryContext = durableMemoryContext(excludingLatestUserText: text)
            if let visualEvidence {
                memoryContext = GemmaConversationPolicy.boundedMemoryContext([
                    memoryContext,
                    visualEvidence.promptContext
                ])
            }
            let responseStream = try await brain.streamResponse(
                to: text,
                memoryContext: memoryContext
            )
            ledger.record("brain_conversation_prepared", fields: [
                "turn_id": turnID.uuidString,
                "conversation_generation": String(responseStream.conversationGeneration),
                "preparation_reason": responseStream.preparationReason,
                "estimated_context_characters": String(responseStream.estimatedContextCharacters)
            ])
            for try await fragment in responseStream.chunks {
                guard generation == turnGeneration else {
                    ledger.record("brain_result_discarded", fields: [
                        "turn_id": turnID.uuidString,
                        "reason": "newer_turn_active"
                    ])
                    return
                }
                if firstBrainFragmentAt == nil {
                    firstBrainFragmentAt = Date()
                    let firstResponseMs = elapsedMilliseconds(since: activeTurnStartedAt)
                    ledger.record("brain_first_fragment", fields: [
                        "turn_id": activeTurnID?.uuidString ?? "unknown",
                        "first_response_ms": String(firstResponseMs),
                        "final_to_first_fragment_ms": String(
                            elapsedMilliseconds(since: activeTurnFinalizedAt)
                        )
                    ])
                }
                response += fragment
                activeAssistantResponse = response
                if let responseIndex {
                    conversation[responseIndex] = ConversationLine(
                        id: conversation[responseIndex].id,
                        role: .assistant,
                        text: response,
                        state: .live
                    )
                } else {
                    conversation.append(ConversationLine(role: .assistant, text: response, state: .live))
                    responseIndex = conversation.indices.last
                }

                let readyChunks = speechAccumulator.append(fragment)
                if !readyChunks.isEmpty {
                    if speechSessionID == nil {
                        speechSessionID = beginLocalBrainTTSStream(
                            turnID: turnID,
                            generation: generation
                        )
                    }
                    if let speechSessionID {
                        tts.appendStreaming(readyChunks, sessionID: speechSessionID)
                    }
                }
            }
            guard generation == turnGeneration else { return }

            let trailingChunks = speechAccumulator.finish()
            if !trailingChunks.isEmpty {
                if speechSessionID == nil {
                    speechSessionID = beginLocalBrainTTSStream(
                        turnID: turnID,
                        generation: generation
                    )
                }
                if let speechSessionID {
                    tts.appendStreaming(trailingChunks, sessionID: speechSessionID)
                }
            }
            if let responseIndex {
                conversation[responseIndex] = ConversationLine(
                    id: conversation[responseIndex].id,
                    role: .assistant,
                    text: response,
                    state: .complete
                )
            }
            persistConversation()
            brainStatus = "gemma_e2b_response_complete"
            ledger.record("brain_completed", fields: [
                "turn_id": activeTurnID?.uuidString ?? "unknown",
                "brain_impl": "gemma_e2b_litertlm",
                "brain_model": await brain.modelIdentity(),
                "brain_runtime": "litert_lm_gpu",
                "elapsed_ms": String(Int(Date().timeIntervalSince(started) * 1_000))
            ])
            if let speechSessionID {
                tts.finishStreaming(sessionID: speechSessionID)
            } else {
                activeAssistantResponse = ""
                ledger.record("tts_skipped", fields: [
                    "turn_id": turnID.uuidString,
                    "reason": "empty_streamed_response"
                ])
            }
        } catch {
            if Task.isCancelled || generation != turnGeneration {
                ledger.record("brain_stream_cancelled", fields: [
                    "turn_id": turnID.uuidString,
                    "reason": Task.isCancelled ? "task_cancelled" : "newer_turn_active"
                ])
                return
            }
            brainStatus = error.localizedDescription
            ledger.record("brain_failed", fields: ["brain_impl": "gemma_e2b_litertlm", "error": error.localizedDescription])
            if let speechSessionID {
                tts.finishStreaming(sessionID: speechSessionID)
            }
        }
        if speechInput.isRunning, !ttsIsSpeaking {
            phase = .listening
            scheduleSemanticRouterWarmIfIdle()
        }
    }

    private func beginLocalBrainTTSStream(turnID: UUID, generation: Int) -> UUID {
        ttsIsSpeaking = true
        pendingBargeIn = false
        bargeInCandidateStartedAt = nil
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        phase = .responding
        ttsStatus = "Supertonic streaming Gemma"
        ledger.record("tts_stream_started", fields: [
            "turn_id": turnID.uuidString,
            "source": "gemma_e2b_sentence_stream",
            "tts_engine": "supertonic_3_coreml",
            "route": audio.state().routeDescription,
            "audio_graph": "shared_voice_processing_engine",
            "elapsed_from_turn_ms": String(elapsedMilliseconds(since: activeTurnStartedAt)),
            "elapsed_from_final_ms": String(elapsedMilliseconds(since: activeTurnFinalizedAt))
        ])
        armVoiceProcessingBargeIn(turnID: turnID, generation: generation)
        Task {
            await jarvis.report(event: "phone_tts_stream_started", fields: [
                "turn_id": turnID.uuidString,
                "source": "gemma_e2b_sentence_stream",
                "route": audio.state().routeDescription
            ])
        }

        return tts.beginStreaming(
            onChunkGenerated: { [weak self] index, total, chunk, stats in
                guard let self, generation == self.turnGeneration else { return }
                self.ttsStatus = "Supertonic streaming \(index + 1)/\(total)"
                self.ledger.record("tts_stream_chunk_generated", fields: [
                    "turn_id": turnID.uuidString,
                    "source": "gemma_e2b_sentence_stream",
                    "index": String(index),
                    "known_total": String(total),
                    "text": chunk,
                    "generation_ms": String(stats.generationMilliseconds),
                    "audio_seconds": String(stats.audioDurationSeconds),
                    "tts_engine": stats.engineID,
                    "voice": stats.voiceName,
                    "normalized_text": stats.normalizedText,
                    "seed": String(stats.seed),
                    "seed_policy": stats.seedPolicy,
                    "runtime_revision": stats.runtimeRevision,
                    "real_time_factor": String(stats.realTimeFactor),
                    "route": stats.audioRoute,
                    "playback_state": stats.playbackState,
                    "lifecycle_epoch": String(stats.lifecycleEpoch),
                    "elapsed_from_final_ms": String(
                        self.elapsedMilliseconds(since: self.activeTurnFinalizedAt)
                    )
                ])
                Task {
                    await self.jarvis.report(event: "phone_tts_stream_chunk_generated", fields: [
                        "turn_id": turnID.uuidString,
                        "source": "gemma_e2b_sentence_stream",
                        "index": String(index),
                        "generation_ms": String(stats.generationMilliseconds),
                        "tts_engine": stats.engineID,
                        "voice": stats.voiceName,
                        "normalized_text": stats.normalizedText,
                        "runtime_revision": stats.runtimeRevision,
                        "route": stats.audioRoute
                    ])
                }
            },
            onPipelineState: { [weak self] snapshot in
                self?.recordTTSPipelineState(
                    snapshot,
                    turnID: turnID,
                    requestID: nil,
                    source: "gemma_e2b_sentence_stream"
                )
            },
            completion: { [weak self] result in
                self?.completeLocalBrainTTSStream(
                    result,
                    turnID: turnID,
                    generation: generation
                )
            }
        )
    }

    private func completeLocalBrainTTSStream(
        _ result: Result<VoiceSpeechPlaybackStats, Error>,
        turnID: UUID,
        generation: Int
    ) {
        guard generation == turnGeneration else { return }
        ttsIsSpeaking = false
        pendingBargeIn = false
        audio.endPlaybackSpeechActivityDetection()
        bargeInCandidateStartedAt = nil
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        activeAssistantResponse = ""

        switch result {
        case let .success(stats):
            ttsStatus = "Supertonic complete"
            ledger.record("tts_stream_finished", fields: [
                "turn_id": turnID.uuidString,
                "source": "gemma_e2b_sentence_stream",
                "tts_engine": stats.engineID,
                "voice": stats.voiceName,
                "runtime_revision": stats.runtimeRevision,
                "stt_source": "parakeet_eou_120m_coreml_160ms",
                "turn_finalization_reason": "hybrid_silero_or_parakeet_eou",
                "brain_impl": "gemma_e2b_litertlm",
                "brain_model": "gemma_e2b_imported_litertlm",
                "brain_runtime": "litert_lm_gpu",
                "vision_model": activeVisualEvidence?.model ?? "none",
                "vision_frame_id": activeVisualEvidence.map { String($0.frameID) } ?? "none",
                "first_response_ms": String(elapsedMilliseconds(since: activeTurnStartedAt, endingAt: firstBrainFragmentAt)),
                "end_to_end_ms": String(elapsedMilliseconds(since: activeTurnStartedAt)),
                "final_to_completion_ms": String(elapsedMilliseconds(since: activeTurnFinalizedAt)),
                "fallback_triggered": "false",
                "fallback_reason": "none",
                "route": stats.audioRoute,
                "playback_state": stats.playbackState,
                "lifecycle_epoch": String(stats.lifecycleEpoch)
            ])
            Task {
                await jarvis.report(event: "phone_tts_stream_finished", fields: [
                    "turn_id": turnID.uuidString,
                    "source": "gemma_e2b_sentence_stream",
                    "route": stats.audioRoute
                ])
            }
        case let .failure(error):
            ttsStatus = "Supertonic failed"
            ledger.record("tts_failed", fields: [
                "turn_id": turnID.uuidString,
                "source": "gemma_e2b_sentence_stream",
                "tts_engine": "supertonic_3_coreml",
                "error": error.localizedDescription
            ])
            Task {
                await jarvis.report(event: "phone_tts_failed", fields: [
                    "turn_id": turnID.uuidString,
                    "source": "gemma_e2b_sentence_stream",
                    "error": error.localizedDescription
                ])
            }
        }

        resumeListeningAfterPlayback(turnID: turnID)
        drainJarvisInboundMessages()
    }

    private func recordTTSPipelineState(
        _ snapshot: VoiceStreamingPipelineSnapshot,
        turnID: UUID,
        requestID: String?,
        source: String
    ) {
        var fields = [
            "turn_id": turnID.uuidString,
            "source": source,
            "event": snapshot.event,
            "accepted_text_chunks": String(snapshot.acceptedTextChunks),
            "next_generation_index": String(snapshot.nextGenerationIndex),
            "generated_ready": String(snapshot.generatedReadyCount),
            "scheduled_outstanding": String(snapshot.scheduledOutstandingCount),
            "completed_clips": String(snapshot.completedClipCount),
            "generation_in_flight": String(snapshot.generationInFlight),
            "input_finished": String(snapshot.inputFinished),
            "max_outstanding": String(snapshot.maxOutstandingClips)
        ]
        if let requestID { fields["request_id"] = requestID }
        ledger.record("tts_stream_pipeline", fields: fields)
        Task {
            await jarvis.report(event: "phone_tts_stream_pipeline", fields: fields)
        }
    }

    private func speakResponse(_ response: String, turnID: UUID, generation: Int) {
        guard generation == turnGeneration else { return }
        if nanoTTSModeEnabled {
            speakNanoResponse(response, turnID: turnID, generation: generation)
            return
        }
        let chunks = ArtemisTTSChunker.chunks(for: response)
        guard !chunks.isEmpty else {
            ttsStatus = "Supertonic skipped empty response"
            ledger.record("tts_skipped", fields: ["reason": "empty_response"])
            return
        }

        ttsIsSpeaking = true
        pendingBargeIn = false
        bargeInCandidateStartedAt = nil
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        activeAssistantResponse = response
        let turnStartedAt = activeTurnStartedAt
        let brainFragmentAt = firstBrainFragmentAt
        phase = .responding
        ttsStatus = "Supertonic generating"
        ledger.record("tts_started", fields: [
            "turn_id": turnID.uuidString,
            "tts_engine": "supertonic_3_coreml",
            "voice": tts.selectedVoiceName,
            "chunks": String(chunks.count),
            "route": audio.state().routeDescription,
            "audio_graph": "shared_voice_processing_engine",
            "elapsed_from_turn_ms": String(elapsedMilliseconds(since: activeTurnStartedAt))
        ])
        armVoiceProcessingBargeIn(turnID: turnID, generation: generation)
        Task {
            await jarvis.report(event: "phone_tts_started", fields: [
                "turn_id": turnID.uuidString,
                "chunks": String(chunks.count),
                "route": audio.state().routeDescription
            ])
        }
        tts.speakQueued(
            chunks,
            onChunkGenerated: { [weak self] index, total, chunk, stats in
                guard let self else { return }
                guard generation == self.turnGeneration else { return }
                self.ttsStatus = "Supertonic speaking \(index + 1)/\(total)"
                self.ledger.record("tts_chunk_generated", fields: [
                    "turn_id": turnID.uuidString,
                    "index": String(index),
                    "total": String(total),
                    "text": chunk,
                    "generation_ms": String(stats.generationMilliseconds),
                    "audio_seconds": String(stats.audioDurationSeconds),
                    "tts_engine": stats.engineID,
                    "voice": stats.voiceName,
                    "normalized_text": stats.normalizedText,
                    "seed": String(stats.seed),
                    "seed_policy": stats.seedPolicy,
                    "runtime_revision": stats.runtimeRevision,
                    "real_time_factor": String(stats.realTimeFactor),
                    "route": stats.audioRoute,
                    "playback_state": stats.playbackState,
                    "audio_engine_running": String(stats.audioEngineRunning),
                    "player_node_playing": String(stats.playerNodePlaying),
                    "scheduled_frames": String(stats.scheduledBufferFrames),
                    "lifecycle_epoch": String(stats.lifecycleEpoch)
                ])
                Task {
                    await self.jarvis.report(event: "phone_tts_chunk_generated", fields: [
                        "turn_id": turnID.uuidString,
                        "index": String(index),
                        "generation_ms": String(stats.generationMilliseconds),
                        "tts_engine": stats.engineID,
                        "voice": stats.voiceName,
                        "normalized_text": stats.normalizedText,
                        "runtime_revision": stats.runtimeRevision,
                        "playback_state": stats.playbackState,
                        "route": stats.audioRoute
                    ])
                }
            },
            completion: { [weak self] result in
                guard let self else { return }
                guard generation == self.turnGeneration else { return }
                self.ttsIsSpeaking = false
                self.pendingBargeIn = false
                self.audio.endPlaybackSpeechActivityDetection()
                self.bargeInCandidateStartedAt = nil
                self.appleSpeechActivityCandidate = false
                self.appleSpeechActivityTimeoutTask?.cancel()
                self.activeAssistantResponse = ""
                switch result {
                case let .success(stats):
                    self.ttsStatus = "Supertonic complete"
                    self.ledger.record("tts_finished", fields: [
                        "turn_id": turnID.uuidString,
                        "tts_engine": stats.engineID,
                        "voice": stats.voiceName,
                        "runtime_revision": stats.runtimeRevision,
                        "stt_source": "parakeet_eou_120m_coreml_160ms",
                        "turn_finalization_reason": "hybrid_silero_or_parakeet_eou",
                        "brain_impl": self.jarvisModeEnabled ? "codex_manager_proxy" : "gemma_e2b_litertlm",
                        "brain_model": self.jarvisModeEnabled ? "codex_low_latency_proxy" : "gemma_e2b_imported_litertlm",
                        "brain_runtime": self.jarvisModeEnabled ? "mac_local_proxy_with_manager_state" : "litert_lm_gpu",
                        "vision_model": self.activeVisualEvidence?.model ?? "none",
                        "vision_frame_id": self.activeVisualEvidence.map { String($0.frameID) } ?? "none",
                        "first_response_ms": String(self.elapsedMilliseconds(since: turnStartedAt, endingAt: brainFragmentAt)),
                        "end_to_end_ms": String(self.elapsedMilliseconds(since: turnStartedAt)),
                        "fallback_triggered": "false",
                        "fallback_reason": "none",
                        "route": stats.audioRoute,
                        "playback_state": stats.playbackState,
                        "audio_engine_running": String(stats.audioEngineRunning),
                        "player_node_playing": String(stats.playerNodePlaying),
                        "scheduled_frames": String(stats.scheduledBufferFrames),
                        "lifecycle_epoch": String(stats.lifecycleEpoch)
                    ])
                    Task {
                        await self.jarvis.report(event: "phone_tts_finished", fields: [
                            "turn_id": turnID.uuidString,
                            "route": stats.audioRoute,
                            "playback_state": stats.playbackState
                        ])
                    }
                case let .failure(error):
                    self.ttsStatus = "Supertonic failed"
                    self.ledger.record("tts_failed", fields: [
                        "turn_id": turnID.uuidString,
                        "tts_engine": "supertonic_3_coreml",
                        "error": error.localizedDescription
                    ])
                    Task {
                        await self.jarvis.report(event: "phone_tts_failed", fields: [
                            "turn_id": turnID.uuidString,
                            "error": error.localizedDescription
                        ])
                    }
                }
                self.resumeListeningAfterPlayback(turnID: turnID)
                self.drainJarvisInboundMessages()
            }
        )
    }

    private func speakNanoResponse(_ response: String, turnID: UUID, generation: Int) {
        guard generation == turnGeneration else { return }
        let chunks = JarvisVoiceTTSChunker.chunks(
            for: response,
            maxChunkBeforeSplit: NanoRemoteTTSConfiguration.maximumChunkCharacters
        )
        guard !chunks.isEmpty else {
            ttsStatus = "Nano remote skipped empty response"
            ledger.record("tts_skipped", fields: [
                "reason": "empty_response",
                "tts_engine": "supertonic_nano_remote"
            ])
            return
        }
        guard let nanoTTS else {
            ttsStatus = "Nano remote unavailable"
            let fields = [
                "turn_id": turnID.uuidString,
                "tts_engine": "supertonic_nano_remote",
                "error": nanoTTSConfigurationError ?? "missing_client",
                "fallback_triggered": "false",
                "fallback_reason": "nano_mode_fail_closed"
            ]
            ledger.record("tts_failed", fields: fields)
            Task { await jarvis.report(event: "phone_tts_failed", fields: fields) }
            resumeListeningAfterPlayback(turnID: turnID)
            return
        }

        ttsIsSpeaking = true
        pendingBargeIn = false
        bargeInCandidateStartedAt = nil
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        activeAssistantResponse = response
        let turnStartedAt = activeTurnStartedAt
        let brainFragmentAt = firstBrainFragmentAt
        phase = .responding
        ttsStatus = "Nano remote generating"
        let startedFields = [
            "turn_id": turnID.uuidString,
            "tts_engine": "supertonic_nano_remote",
            "voice": ProcessInfo.processInfo.environment["NANO_TTS_VOICE"]
                ?? NanoRemoteTTSConfiguration.defaultVoice,
            "chunks": String(chunks.count),
            "route": audio.state().routeDescription,
            "audio_graph": "shared_voice_processing_engine",
            "elapsed_from_turn_ms": String(elapsedMilliseconds(since: activeTurnStartedAt)),
            "fallback_triggered": "false",
            "fallback_reason": "none"
        ]
        ledger.record("tts_started", fields: startedFields)
        armVoiceProcessingBargeIn(turnID: turnID, generation: generation)
        Task { await jarvis.report(event: "phone_tts_started", fields: startedFields) }

        nanoTTS.speakQueued(
            chunks,
            onChunkGenerated: { [weak self] index, total, stats in
                guard let self, generation == self.turnGeneration else { return }
                self.ttsStatus = "Nano remote speaking \(index + 1)/\(total)"
                var fields = stats.telemetryFields
                fields["turn_id"] = turnID.uuidString
                fields["index"] = String(index)
                fields["total"] = String(total)
                self.ledger.record("tts_chunk_generated", fields: fields)
                Task {
                    await self.jarvis.report(event: "phone_tts_chunk_generated", fields: fields)
                }
            },
            completion: { [weak self] result in
                guard let self, generation == self.turnGeneration else { return }
                self.ttsIsSpeaking = false
                self.pendingBargeIn = false
                self.audio.endPlaybackSpeechActivityDetection()
                self.bargeInCandidateStartedAt = nil
                self.appleSpeechActivityCandidate = false
                self.appleSpeechActivityTimeoutTask?.cancel()
                self.activeAssistantResponse = ""
                switch result {
                case let .success(stats):
                    self.ttsStatus = "Nano remote complete"
                    var fields = stats.telemetryFields
                    fields["turn_id"] = turnID.uuidString
                    fields["stt_source"] = "parakeet_eou_120m_coreml_160ms"
                    fields["turn_finalization_reason"] = "hybrid_silero_or_parakeet_eou"
                    fields["brain_impl"] = self.jarvisModeEnabled
                        ? "codex_manager_proxy"
                        : "gemma_e2b_litertlm"
                    fields["brain_model"] = self.jarvisModeEnabled
                        ? "codex_low_latency_proxy"
                        : "gemma_e2b_imported_litertlm"
                    fields["brain_runtime"] = self.jarvisModeEnabled
                        ? "mac_local_proxy_with_manager_state"
                        : "litert_lm_gpu"
                    fields["vision_model"] = "none"
                    fields["vision_frame_id"] = "none"
                    fields["first_response_ms"] = String(
                        self.elapsedMilliseconds(since: turnStartedAt, endingAt: brainFragmentAt)
                    )
                    fields["end_to_end_ms"] = String(self.elapsedMilliseconds(since: turnStartedAt))
                    self.ledger.record("tts_finished", fields: fields)
                    Task { await self.jarvis.report(event: "phone_tts_finished", fields: fields) }
                case let .failure(error):
                    self.ttsStatus = "Nano remote failed"
                    let fields = [
                        "turn_id": turnID.uuidString,
                        "tts_engine": "supertonic_nano_remote",
                        "error": error.localizedDescription,
                        "fallback_triggered": "false",
                        "fallback_reason": "nano_mode_fail_closed"
                    ]
                    self.ledger.record("tts_failed", fields: fields)
                    Task { await self.jarvis.report(event: "phone_tts_failed", fields: fields) }
                }
                self.resumeListeningAfterPlayback(turnID: turnID)
                self.drainJarvisInboundMessages()
            }
        )
    }

    private func resumeListeningAfterPlayback(turnID: UUID) {
        if adaptiveRouteRecoveryPending {
            scheduleAdaptiveAudioRouteRecovery(trigger: "playback_completed")
        }
        if speechInput.isRunning {
            phase = .listening
            scheduleSemanticRouterWarmIfIdle()
        }
        Task { [weak self] in
            guard let self else { return }
            await self.speechInput.resetTranscriptState()
            let fields = [
                "turn_id": turnID.uuidString,
                "speech_input_running": String(self.speechInput.isRunning),
                "route": self.audio.state().routeDescription,
                "transcript_state_reset": "true"
            ]
            self.ledger.record("listening_resumed", fields: fields)
            await self.jarvis.report(event: "phone_listening_resumed", fields: fields)
        }
    }

    private func elapsedMilliseconds(since start: Date?, endingAt end: Date? = nil) -> Int {
        guard let start else { return -1 }
        return Int((end ?? Date()).timeIntervalSince(start) * 1_000)
    }

    private func persistConversation() {
        conversationStore.save(conversation)
    }

    private func durableMemoryContext(excludingLatestUserText: String? = nil) -> String {
        var memoryLines = conversation
        if let excludingLatestUserText,
           let latest = memoryLines.last,
           latest.role == .user,
           latest.text == excludingLatestUserText {
            memoryLines.removeLast()
        }
        let rendered = memoryLines.suffix(16).map { line in
            "\(line.role == .user ? "Devansh" : "Jarvis"): \(line.text)"
        }
        return GemmaConversationPolicy.boundedMemoryContext(rendered)
    }

    private func scheduleHybridEndpoint(
        trigger: String,
        speechDurationSeconds: TimeInterval? = nil,
        maximumVADProbability: Float? = nil
    ) {
        endpointTask?.cancel()
        guard !ttsIsSpeaking else { return }
        guard sileroVADReady else {
            ledger.record("hybrid_endpoint_skipped", fields: [
                "trigger": trigger,
                "reason": "silero_vad_not_ready",
                "parakeet_eou_remains_active": "true"
            ])
            return
        }
        let hadPartial = !draftTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        endpointTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.hybridEndpointDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, !self.vadSpeechActive, !self.ttsIsSpeaking else { return }
            guard let transcript = await self.speechInput.finalizeCurrentTranscript() else {
                self.ledger.record("stt_empty_after_vad", fields: [
                    "endpoint_trigger": trigger,
                    "had_partial_callback": String(hadPartial),
                    "speech_input_running": String(self.speechInput.isRunning),
                    "speech_duration_ms": String(Int((speechDurationSeconds ?? 0) * 1_000)),
                    "maximum_vad_probability": String(maximumVADProbability ?? 0)
                ])
                self.handleEmptyASRSegment(
                    trigger: trigger,
                    durationSeconds: speechDurationSeconds,
                    maximumVADProbability: maximumVADProbability
                )
                return
            }
            self.recognizerProven = true
            self.consecutiveMeaningfulSegmentsWithoutTranscript = 0
            self.ledger.record("stt_final_received", fields: [
                "transcript": transcript,
                "stt_source": "parakeet_eou_120m_coreml_160ms",
                "endpoint_trigger": trigger
            ])
            self.acceptFinalTranscript(
                transcript,
                source: "parakeet_hybrid",
                finalizationReason: "silero_speech_end_700ms"
            )
        }
    }

    private func handleEmptyASRSegment(
        trigger: String,
        durationSeconds: TimeInterval?,
        maximumVADProbability: Float?
    ) {
        guard let durationSeconds,
              let maximumVADProbability,
              VoiceTurnTakingPolicy.isMeaningfulSpeechSegment(
                  durationSeconds: durationSeconds,
                  maximumVADProbability: maximumVADProbability
              ) else { return }

        consecutiveMeaningfulSegmentsWithoutTranscript += 1
        recognizerProven = false
        ledger.record("stt_health_miss", fields: [
            "trigger": trigger,
            "consecutive_misses": String(consecutiveMeaningfulSegmentsWithoutTranscript),
            "speech_duration_ms": String(Int(durationSeconds * 1_000)),
            "maximum_vad_probability": String(maximumVADProbability)
        ])
        guard consecutiveMeaningfulSegmentsWithoutTranscript >= 2 else { return }
        sttRuntimeStatus = "Recovering Parakeet EOU"
        recoverSpeechCapture(trigger: "asr_health_watchdog", forceRestart: true)
    }

    private func armVoiceProcessingBargeIn(turnID: UUID, generation: Int) {
        appleSpeechActivityCandidate = false
        appleSpeechActivityTimeoutTask?.cancel()
        audio.endPlaybackSpeechActivityDetection()
        let fields = [
            "turn_id": turnID.uuidString,
            "input_muted": "false",
            "capture_policy": "continuous_aec_uplink",
            "confirmation_policy": "silero_plus_non_echo_parakeet"
        ]
        ledger.record("voice_processing_barge_in_armed", fields: fields)
        Task {
            await jarvis.report(event: "phone_voice_processing_barge_in_armed", fields: fields)
        }
    }

    private func beginContinuousBargeInCandidate(probability: Float) {
        guard ttsIsSpeaking, !pendingBargeIn else { return }
        pendingBargeIn = true
        bargeInCandidateStartedAt = Date()
        let turnID = activeTurnID
        let generation = turnGeneration
        let fields = [
            "turn_id": turnID?.uuidString ?? "unknown",
            "reason": "silero_speech_started_continuous_aec_capture",
            "probability": String(probability),
            "input_muted": "false"
        ]
        ledger.record("barge_in_candidate", fields: fields)
        Task {
            await jarvis.report(event: "phone_barge_in_candidate", fields: fields)
        }

        appleSpeechActivityTimeoutTask?.cancel()
        appleSpeechActivityTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard let self,
                  generation == self.turnGeneration,
                  self.ttsIsSpeaking,
                  self.pendingBargeIn else { return }
            self.pendingBargeIn = false
            self.bargeInCandidateStartedAt = nil
            await self.speechInput.resetTranscriptState()
            let fields = [
                "turn_id": turnID?.uuidString ?? "unknown",
                "reason": "no_non_echo_asr_corroboration",
                "capture_policy": "continuous_aec_uplink"
            ]
            self.ledger.record("voice_processing_candidate_expired", fields: fields)
            Task {
                await self.jarvis.report(event: "phone_barge_in_candidate_expired", fields: fields)
            }
        }
    }

    private func confirmBargeIn(
        transcript: String,
        reason: String = "silero_plus_non_echo_parakeet_partial"
    ) {
        guard ttsIsSpeaking else { return }
        audio.endPlaybackSpeechActivityDetection()
        appleSpeechActivityTimeoutTask?.cancel()
        appleSpeechActivityCandidate = false
        if currentJarvisRequestID != nil || activeJarvisStreamRequestID != nil {
            cancelActiveJarvisRequest(reason: "confirmed_barge_in")
        } else {
            stopSelectedTTS()
            brainTask?.cancel()
            Task { [weak self] in
                guard let self else { return }
                let cancellationError = await self.brain.cancelCurrentResponse()
                self.ledger.record("brain_cancelled_barge_in", fields: [
                    "reason": reason,
                    "status": cancellationError == nil ? "cancelled" : "failed",
                    "error": cancellationError ?? "none"
                ])
            }
        }
        ttsIsSpeaking = false
        pendingBargeIn = false
        bargeInCandidateStartedAt = nil
        activeAssistantResponse = ""
        turnGeneration += 1
        finalizedTranscriptForTurn = nil
        ttsStatus = nanoTTSModeEnabled ? "Nano remote interrupted" : "Supertonic interrupted"
        ledger.record("tts_cancelled_barge_in", fields: [
            "reason": reason,
            "transcript": transcript
        ])
        Task {
            await jarvis.report(event: "phone_tts_cancelled_barge_in", fields: [
                "reason": reason,
                "transcript": transcript
            ])
        }
        phase = .userSpeaking
    }

    private func isExplicitBargeIn(_ transcript: String) -> Bool {
        let words = Set(normalizedWords(transcript))
        return !words.isDisjoint(with: ["stop", "wait", "pause", "cancel"])
    }

    private func isControlOnlyBargeIn(
        _ transcript: String,
        allowClippedStopAlias: Bool = false
    ) -> Bool {
        let words = Set(normalizedWords(transcript))
        let controls: Set<String> = ["stop", "wait", "pause", "cancel"]
        let permitted: Set<String> = controls.union(["please", "hey", "artemis", "jarvis"])
        if !words.isDisjoint(with: controls), words.isSubset(of: permitted) {
            return true
        }
        let clippedStopAliases: Set<String> = ["op", "top", "up"]
        return allowClippedStopAlias
            && words.count == 1
            && !words.isDisjoint(with: clippedStopAliases)
    }

    private func shouldConfirmBargeIn(_ transcript: String, isFinal: Bool) -> Bool {
        if appleSpeechActivityCandidate { return true }
        if isExplicitBargeIn(transcript) { return true }
        if isFinal { return true }
        guard normalizedWords(transcript).count >= 3,
              let startedAt = bargeInCandidateStartedAt else { return false }
        return Date().timeIntervalSince(startedAt) >= 0.25
    }

    private func isLikelyPlaybackEcho(_ transcript: String) -> Bool {
        let partial = normalizedWords(transcript)
        let response = normalizedWords(activeAssistantResponse)
        guard !partial.isEmpty, !response.isEmpty else { return false }
        if isExplicitBargeIn(transcript) { return false }
        // A single common word is not enough evidence to discard a real
        // interruption. Parakeet often emits "I" before "I told you...".
        guard partial.count >= 2 else { return false }
        let partialPhrase = partial.joined(separator: " ")
        let responsePhrase = response.joined(separator: " ")
        if responsePhrase.contains(partialPhrase) { return true }

        let windowSize = min(partial.count, response.count)
        guard windowSize > 0 else { return false }
        let partialCharacters = partial.joined()
        for start in 0...(response.count - windowSize) {
            let candidate = response[start..<(start + windowSize)].joined()
            if characterSimilarity(partialCharacters, candidate) >= 0.72 {
                return true
            }
        }
        return false
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private func characterSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 1 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(insertion, min(deletion, substitution)))
            }
            previous = current
        }
        return 1 - (Double(previous[right.count]) / Double(longest))
    }
}

@MainActor
extension VoiceSessionModel: ParakeetSpeechInputDelegate {
    func speechInputDidUpdateTranscript(_ transcript: String, isFinal: Bool) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recognizerProven = true
        consecutiveMeaningfulSegmentsWithoutTranscript = 0
        if ttsIsSpeaking {
            if isFinal, VoiceTurnTakingPolicy.isNonInterruptingBackchannel(trimmed) {
                pendingBargeIn = false
                bargeInCandidateStartedAt = nil
                appleSpeechActivityCandidate = false
                appleSpeechActivityTimeoutTask?.cancel()
                phase = .responding
                ledger.record("barge_in_backchannel_observed", fields: [
                    "transcript": trimmed,
                    "policy": "non_interrupting_final_acknowledgment"
                ])
                Task { await speechInput.resetTranscriptState() }
                return
            }
            if isLikelyPlaybackEcho(trimmed) {
                ledger.record("stt_playback_echo_suppressed", fields: [
                    "transcript": trimmed,
                    "is_final": String(isFinal),
                    "policy": "fuzzy_playback_window",
                    "barge_in_candidate_retained": String(pendingBargeIn)
                ])
                // Keep the candidate and its original start time alive. A
                // short echo-like prefix can be the beginning of a distinct
                // human interruption; the existing timeout still rejects a
                // stream that remains echo-only.
                if isFinal { Task { await speechInput.resetTranscriptState() } }
                return
            }
            if shouldConfirmBargeIn(trimmed, isFinal: isFinal) {
                let controlOnly = isControlOnlyBargeIn(
                    trimmed,
                    allowClippedStopAlias: appleSpeechActivityCandidate
                )
                confirmBargeIn(transcript: trimmed)
                if controlOnly {
                    finalizedTranscriptForTurn = trimmed
                    ledger.record("barge_in_control_consumed", fields: [
                        "transcript": trimmed,
                        "policy": "local_reflex_no_brain_turn",
                        "clipped_stop_alias": String(!isExplicitBargeIn(trimmed))
                    ])
                    Task { await speechInput.resetTranscriptState() }
                    return
                }
            } else {
                ledger.record("barge_in_deferred", fields: [
                    "transcript": trimmed,
                    "is_final": String(isFinal),
                    "reason": "awaiting_non_echo_evidence"
                ])
                return
            }
        }
        draftTranscript = trimmed
        ledger.record(isFinal ? "stt_final_received" : "stt_partial", fields: [
            "transcript": trimmed,
            "stt_source": "parakeet_eou_120m_coreml_160ms"
        ])
        Task {
            await jarvis.report(event: isFinal ? "phone_stt_final" : "phone_stt_partial", fields: [
                "transcript": trimmed
            ])
        }
        if isFinal {
            endpointTask?.cancel()
            acceptFinalTranscript(
                trimmed,
                source: "parakeet_eou",
                finalizationReason: "parakeet_eou_640ms"
            )
        } else if !vadSpeechActive {
            scheduleHybridEndpoint(trigger: "stable_partial_without_active_vad")
        }
    }

    func speechInputDidDetectVAD(_ event: SileroVADDetectionEvent) {
        var completedSpeechDuration: TimeInterval?
        var completedMaximumProbability: Float?
        if event.phase == .ready {
            sileroVADReady = true
            ledger.record("hybrid_endpoint_ready", fields: [
                "reason": event.reason,
                "fallback_triggered": "false"
            ])
        } else if event.phase == .unavailable {
            sileroVADReady = false
            endpointTask?.cancel()
            endpointTask = nil
            ledger.record("hybrid_endpoint_degraded", fields: [
                "reason": event.reason,
                "parakeet_eou_remains_active": "true",
                "stable_partial_timeout_enabled": "false"
            ])
        } else if event.phase == .speechStarted {
            if experimentalSemanticRouterEnabled, !semanticRouterWarmed {
                semanticRouterWarmTask?.cancel()
                semanticRouterWarmTask = nil
            }
            endpointTask?.cancel()
            endpointTask = nil
            vadSpeechActive = true
            let now = Date()
            speechStartedAt = now
            currentVADSpeechStartedAt = now
            currentVADMaximumProbability = event.probability
            if ttsIsSpeaking {
                beginContinuousBargeInCandidate(probability: event.probability)
            } else {
                finalizedTranscriptForTurn = nil
            }
        } else if event.phase == .probability, vadSpeechActive {
            currentVADMaximumProbability = max(currentVADMaximumProbability, event.probability)
        } else if event.phase == .speechEnded {
            vadSpeechActive = false
            completedSpeechDuration = currentVADSpeechStartedAt.map { Date().timeIntervalSince($0) }
            completedMaximumProbability = max(currentVADMaximumProbability, event.probability)
            currentVADSpeechStartedAt = nil
            currentVADMaximumProbability = 0
            if !ttsIsSpeaking || !pendingBargeIn {
                bargeInCandidateStartedAt = nil
            }
        }
        let shouldRecordVAD = event.phase != .probability
            || Date().timeIntervalSince(lastVADProbabilityTelemetryAt) >= 1
        if shouldRecordVAD {
            if event.phase == .probability { lastVADProbabilityTelemetryAt = Date() }
            ledger.record("vad_\(event.phase.rawValue)", fields: [
                "probability": String(event.probability),
                "reason": event.reason
            ])
        }
        if event.phase != .probability {
            Task {
                await jarvis.report(event: "phone_vad_\(event.phase.rawValue)", fields: [
                    "probability": String(event.probability),
                    "reason": event.reason
                ])
            }
        }
        switch event.phase {
        case .speechStarted:
            if !ttsIsSpeaking { phase = .userSpeaking }
        case .speechEnded:
            if ttsIsSpeaking {
                phase = .responding
            } else if speechInput.isRunning {
                phase = .listening
                scheduleHybridEndpoint(
                    trigger: "silero_speech_ended",
                    speechDurationSeconds: completedSpeechDuration,
                    maximumVADProbability: completedMaximumProbability
                )
                scheduleSemanticRouterWarmIfIdle()
            }
        default: break
        }
    }

    func speechInputDidObserveAudioLevel(rms: Float, peak: Float) {
        latestAudioLevel = rms
        guard Date().timeIntervalSince(lastAudioLevelTelemetryAt) >= 1 else { return }
        lastAudioLevelTelemetryAt = Date()
        ledger.record("audio_level", fields: ["rms": String(rms), "peak": String(peak)])
    }

    func speechInputDidReplayStartupAudio(durationSeconds: Double, bufferCount: Int) {
        ledger.record("stt_startup_audio_replayed", fields: [
            "duration_ms": String(Int(durationSeconds * 1_000)),
            "buffer_count": String(bufferCount),
            "maximum_retained_ms": "2500",
            "source": "shared_full_duplex_capture"
        ])
    }

    func speechInputDidFail(_ error: Error) {
        ledger.record("speech_error", fields: ["error": error.localizedDescription])
        if !speechInput.isRunning { phase = .unavailable(error.localizedDescription) }
    }

    func speechInputDidUpdateRuntimeStatus(_ status: String) {
        sttRuntimeStatus = status
        ledger.record("stt_runtime_status", fields: ["status": status])
    }
}
