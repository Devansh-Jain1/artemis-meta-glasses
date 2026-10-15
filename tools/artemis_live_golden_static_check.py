#!/usr/bin/env python3
"""Static guardrails for Artemis live golden architecture wiring."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Artemis" / "Artemis" / "ArtemisApp.swift"
PROJECT = ROOT / "Artemis" / "Artemis.xcodeproj" / "project.pbxproj"

source = APP.read_text()
project = PROJECT.read_text()
errors: list[str] = []

if "--run-live-golden-loop" not in source:
    errors.append("Missing --run-live-golden-loop launch path.")

if "--run-display-hud-coexistence" not in source:
    errors.append("Missing explicit --run-display-hud-coexistence launch path for camera+HUD proof.")

if "import MWDATDisplay" not in source:
    errors.append("Artemis must import MWDATDisplay for native glasses HUD proof.")

if "MWDATDisplay" not in project:
    errors.append("Artemis target must link the MWDATDisplay package product.")

for marker in [
    "display_hud_attach_started",
    "display_hud_started",
    "display_hud_send_started",
    "display_hud_send_completed",
    "display_hud_coexistence_sample",
]:
    if f'"{marker}"' not in source:
        errors.append(f"Missing Display HUD coexistence event: {marker}")

for symbol in [
    "configureDisplayHUD(",
    "configurePersistentEligibilityRetry(",
    "updateDisplayHUD(",
    "DisplayHUDSnapshot",
    "sendDisplayHUDSnapshot(",
]:
    if symbol not in source:
        errors.append(f"Missing Display HUD integration symbol: {symbol}")

if "wearable.configurePersistentEligibilityRetry(enabled: false)" not in source:
    errors.append("Live/HUD validation must use bounded DAT eligibility retries and fail closed when Meta exposes no wearable.")

if "DATLifecyclePolicy.transition(" not in source or "DATLifecyclePolicy.frameMetrics(" not in source:
    errors.append("Live DAT stream handling must use DATLifecyclePolicy for state and frame freshness metrics.")

for marker in [
    '"dat_lifecycle_state"',
    '"dat_frame_age_ms"',
    '"dat_ingest_latency_ms"',
    '"dat_dropped_frames"',
    '"dat_device_unavailable_reason"',
]:
    if marker not in source:
        errors.append(f"DAT lifecycle telemetry missing {marker}.")

if "runLiveGoldenTurn(" not in source or "GoldenBrainRouter" not in source:
    errors.append("Live golden path must route through GoldenBrainRouter/runLiveGoldenTurn.")

if "private let brain = LocalBrainService()" in source or "brain.respond(" in source:
    errors.append("Live/golden path must not instantiate or call LocalBrainService.")

if "private let perception = LocalPerceptionService()" in source or "perception.analyze(" in source:
    errors.append("Live/golden path must not instantiate or call LocalPerceptionService.")

if "actor LocalBrainService" in source or "struct LocalBrainRuntimeContext" in source:
    errors.append("Scaffold LocalBrainService must not live in Artemis product source.")

if "actor LocalPerceptionService" in source:
    errors.append("Scaffold LocalPerceptionService must not live in Artemis product source.")

if "MockWearableSession" in source:
    errors.append("MockWearableSession must not live in Artemis product source.")

if "private let sentinelFrameStride = 96" not in source:
    errors.append("Live LFM sentinel should use a sparse background cadence; on-demand vision handles visual turns.")

if "format.scale = 1" not in source:
    errors.append("Live LFM frame compression must force renderer scale 1.0 to avoid 3x iPhone image token blowups.")

if "runOnDemandVisionForTurn(" not in source or "shouldRefreshVisionForTurn(" not in source:
    errors.append("Live golden visual turns must refresh latest-frame LFM on demand before routing to the brain.")

if '"vision_refresh_reason"' not in source:
    errors.append("On-demand vision refresh must log why the deep vision fallback was used.")

if "private let liveGoldenContextTokenLimit = 512" not in source:
    errors.append("Live GoldenBrainRouter must use the bounded 512-token context cap; 192 total input+output tokens is too small for live turns.")

if "maxNumTokens: liveGoldenContextTokenLimit" not in source:
    errors.append("Live GoldenBrainRouter must use liveGoldenContextTokenLimit instead of an inline token cap.")

for required_cap in [
    "history.suffix(4)",
    "userPrompt.prefix(140)",
    "vision.summary.prefix(72)",
    "vision.visibleText.prefix(24)",
]:
    if required_cap not in source:
        errors.append(f"Live GoldenBrainRouter prompt is not compact enough: missing {required_cap}.")

if "live_router_json_v5_18w_512tok_freshconv" not in source:
    errors.append("Live turn evidence must identify the 512-token fresh-conversation GoldenBrainRouter contract.")

if 'systemMessage: Message("Artemis.")' not in source:
    errors.append("LiteRT live/router conversations must keep the system message tiny under the bounded live token budget.")

if "reuseConversation: false" not in source:
    errors.append("Live GoldenBrainRouter must create a fresh LiteRT conversation per turn and carry context through TurnLedger.")

if "func makeConversation(for engine:" not in source:
    errors.append("LiteRT engine reuse must be separated from per-turn conversation reuse.")

if "let preserveLiveGoldenTurn = liveGoldenModeEnabled" not in source:
    errors.append("startValidation must preserve any in-flight live golden turn when the DAT stream starts.")

if '"startup_greeting_skipped_inflight"' not in source:
    errors.append("Startup greeting queue must skip and log when a live golden turn is already in flight.")

turn_manager_source = "\n".join(
    (ROOT / "Artemis" / "Artemis" / "Core" / "TurnTakingManager.swift").read_text().splitlines()
)
if "turnTakingDidTimeoutProcessing" not in turn_manager_source:
    errors.append("TurnTakingManager must report slow brain processing instead of silently resetting to listening.")
if "Processing timeout - returning to listening" in turn_manager_source:
    errors.append("TurnTakingManager must not silently return to listening while the live brain turn is unresolved.")
if "voice_processing_slow" not in source:
    errors.append("Artemis must log slow brain processing as live evidence.")

if "STTTurnFinalizationPolicy.decision(" not in source:
    errors.append("Live golden STT partial routing must use the deterministic STTTurnFinalizationPolicy.")

if "stable_partial_timeout_gated" in source:
    errors.append("STT finalization must log the policy reason, not the old generic stable_partial_timeout_gated label.")

for marker in ['"stt_stable_partial_count"', '"stt_silence_ms"']:
    if marker not in source:
        errors.append(f"STT auto-finalization telemetry missing {marker}.")

if "live_json_1fps" not in source:
    errors.append("Live vision prompt mode should identify the optimized JSON 1 FPS contract.")

if "VisionFreshnessPolicy.classify(" not in source:
    errors.append("Live golden routing must classify vision freshness before brain routing.")

if "no_direct_visual_claim" not in source:
    errors.append("Live GoldenBrainRouter prompt must forbid direct visual claims for stale/low-confidence vision.")

if "HierarchicalVisionPolicy.decide(" not in source:
    errors.append("Live vision probes must record the hierarchical sentinel/OCR/deep-inspector policy decision.")

for marker in ['"vision_policy_lane"', '"vision_policy_reason"', '"vision_policy_evidence_class"']:
    if marker not in source:
        errors.append(f"Hierarchical vision policy telemetry missing {marker}.")

required_evidence_fields = [
    "stt_source",
    "turn_finalization_reason",
    "brain_impl",
    "brain_model",
    "brain_runtime",
    "brain_output_contract",
    "vision_source",
    "vision_model",
    "vision_prompt_mode",
    "vision_frame_id",
    "vision_timestamp_ms",
    "vision_age_ms_at_turn",
    "vision_freshness_state",
    "vision_direct_claim_allowed",
    "tts_engine",
    "first_response_ms",
    "end_to_end_ms",
    "fallback_triggered",
    "fallback_reason",
]
for field in required_evidence_fields:
    if f'"{field}"' not in source:
        errors.append(f"Missing live turn evidence field: {field}")

if "disabled_clean_audio_gate" in source or "stop_stt_before_kokoro" in source:
    errors.append("Live golden mode must keep barge-in possible; disabled clean-audio STT gate is forbidden.")

if "enableDuplexBargeInRoute()" not in source:
    errors.append("Live golden Kokoro output must use a duplex barge-in route so STT input stays alive during/after TTS.")

if "speechOutput.enableDuplexBargeInRoute()" not in source:
    errors.append("Live golden TTS path must call enableDuplexBargeInRoute before Kokoro playback.")

if "route_policy\": \"live_default_non_call\"" not in source:
    errors.append("Live golden route telemetry must identify the default non-call route.")

if "restartListeningAfterSpeechOutput(reason:" not in source:
    errors.append("Live golden mode must force-rebuild Apple STT after Kokoro/TTS route churn.")

if '"voice_stt_restart_after_tts_requested"' not in source or '"voice_stt_restart_after_tts_starting"' not in source:
    errors.append("Live golden STT restart after TTS must be logged as evidence.")

if '"voice_stt_audio_level"' not in source or "speechInputDidObserveAudioLevel" not in source:
    errors.append("Live golden STT must log mic RMS/peak evidence so fake-listening can be detected.")

if '"voice_stt_input_too_quiet"' not in source or "liveGoldenQuietInputPeakThreshold" not in source:
    errors.append("Live golden STT must fail visibly when the mic tap is alive but input is too quiet for STT.")

if "speechOutput.enablePrivateGlassesDuplexRoute()" in source:
    errors.append("Live golden TTS path must not force the private Bluetooth HFP glasses route by default.")

if "speechInput.requiredAudioRoutePolicy = liveGoldenModeEnabled ? .metaGlassesOnly : nil" in source:
    errors.append("Live golden STT path must not force the private Bluetooth HFP glasses route by default.")

if "startVoiceBridge(armListeningImmediately: false)" not in source:
    errors.append("Startup live golden path must arm Voice Bridge without starting STT before Kokoro route preflight.")

if "PrivateAudioRoutePicker" not in source or "MPVolumeView" not in source:
    errors.append("Voice panel must expose the system audio route picker for private glasses route selection.")

if "refreshAudioRouteDiagnostics()" not in source or "audioRouteSummary" not in source:
    errors.append("Voice panel must expose current audio route diagnostics for private route debugging.")

if "retryPrivateAudioRouteSpeech()" not in source or "Retry Private Audio" not in source:
    errors.append("Voice panel must expose an explicit private Kokoro retry after route selection.")

retry_index = source.find("func retryPrivateAudioRouteSpeech()")
retry_window = source[retry_index : retry_index + 900] if retry_index != -1 else ""
if retry_index != -1 and "speakGoldenResponseWithBargeIn(text:" not in retry_window:
    errors.append("Private audio retry must use the live golden private Kokoro route path.")

if "AVAudioSession.routeChangeNotification" not in source or "handleAudioRouteChanged" not in source:
    errors.append("Artemis must observe audio route changes and update private route diagnostics.")

if "voice_private_audio_auto_retry" not in source or "pendingPrivateAudioRetryText" not in source:
    errors.append("Artemis must keep explicit private Kokoro retry diagnostics separate from default live audio.")

if '"required_route": sttCalibrationModeEnabled ? pendingSTTCalibrationRoute.rawValue : (liveGoldenModeEnabled ? "default_non_call" : "none")' not in source:
    errors.append("Live golden STT telemetry must identify the default non-call route while preserving explicit STT calibration routes.")

if "try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .mixWithOthers])" not in source:
    errors.append("Live golden Apple STT must support voiceChat Bluetooth HFP duplex capture.")

if "input.portType == .bluetoothHFP || input.portType == .bluetoothLE" not in source:
    errors.append("Live golden audio route must prefer an exposed Bluetooth HFP/LE input when iOS provides one.")

if "try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])" not in source:
    errors.append("Apple STT non-live default path must keep measurement mode without allowBluetoothHFP.")

speech_input_start_match = re.search(
    r"func start\(\) async throws \{(?P<body>.*?)\n\s*\}\n\n\s*func stop\(",
    source,
    re.S,
)
if speech_input_start_match and ".allowBluetoothHFP" in speech_input_start_match.group("body").split("} else {", 1)[-1]:
    errors.append("Apple STT default branch must not request Bluetooth HFP.")

if speech_input_start_match:
    speech_input_start_body = speech_input_start_match.group("body")
    if "SpeechInputError.privateAudioRouteNotAllowed" not in speech_input_start_body:
        errors.append("Apple STT explicit private-route diagnostic branch must fail closed if glasses route validation fails.")

kokoro_source = "\n".join(
    (ROOT / "Artemis" / "Artemis" / "Core" / "KokoroSpeechOutput.swift").read_text().splitlines()
)
route_policy_source = "\n".join(
    (ROOT / "Artemis" / "Artemis" / "Core" / "ArtemisAudioRoutePolicy.swift").read_text().splitlines()
)
if "case .duplexBargeIn" not in kokoro_source:
    errors.append("KokoroSpeechOutput must expose a duplex barge-in audio route.")

if "activateMetaGlassesDuplexSession(resetActiveSession: true)" not in kokoro_source:
    errors.append("Kokoro live duplex route must use the shared private Meta/Ray-Ban activation path.")

if (
    "static func activateMetaGlassesDuplexSession" not in route_policy_source
    or "ArtemisAudioRoutePolicy.metaGlassesOnly" not in route_policy_source
    or "decision.isAllowed" not in route_policy_source
):
    errors.append("Shared private duplex route must fail closed unless the active output is the Meta/Ray-Ban glasses route.")

if "case .privateGlassesDuplex" not in kokoro_source:
    errors.append("Kokoro private glasses route must remain available as an explicit diagnostic path.")

speech_start_match = re.search(
    r"func speechOutputDidStart\(text: String, engine: SpeechOutputEngine\) \{(?P<body>.*?)\n\s*\}",
    source,
    re.S,
)
if speech_start_match and "stopListening()" in speech_start_match.group("body"):
    errors.append("speechOutputDidStart must not stop STT; barge-in must remain armed during TTS.")

speech_fail_match = re.search(
    r"func speechOutputDidFail\(text: String, engine: SpeechOutputEngine, error: Error\) \{(?P<body>.*?)\n\s*\}",
    source,
    re.S,
)
if speech_fail_match:
    speech_fail_body = speech_fail_match.group("body")
    if "shouldResumeListeningAfterSpeechOutputFailure(error)" not in speech_fail_body:
        errors.append("speechOutputDidFail must not rearm STT after private route failures.")

if "liveVisionContext" not in source or "vision.summary" not in source:
    errors.append("GoldenBrainRouter prompt must include compact latest-frame vision context.")

if "vision: LiveVisionContext" not in source:
    errors.append("Live turn evidence must receive the per-turn vision snapshot, not read mutable liveVisionContext later.")

for event_name in [
    "voice_stt_final",
    "voice_turn_completed",
    "voice_tts_started",
    "voice_tts_finished",
]:
    event_index = source.find(f'"{event_name}"')
    if event_index == -1:
        errors.append(f"Missing live assistant event: {event_name}")
        continue
    event_window = source[event_index : event_index + 450]
    if '"turn_id"' not in event_window:
        errors.append(f"{event_name} must include a turn_id for STT/router/TTS correlation.")

if '"golden_turn_completed"' not in source:
    errors.append("Missing live assistant event: golden_turn_completed")
if '"turn_id": turnID' not in source:
    errors.append("liveTurnEvidencePayload must include turn_id for golden_turn_completed correlation.")

if "turnLedger" not in source or "appendTurnLedger" not in source:
    errors.append("Live golden turns must preserve short-term turn ledger context.")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)

print("PASS: Artemis live golden architecture guardrails hold.")
