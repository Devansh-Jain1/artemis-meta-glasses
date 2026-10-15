#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import sys
import tempfile
import threading
import time
import unittest
from http.client import HTTPConnection
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import artemis_log_server


ROOT = Path(__file__).resolve().parents[1]


class ArtemisLiveContractTests(unittest.TestCase):
    def test_live_evidence_schema_and_sample_cover_required_fields(self) -> None:
        schema = json.loads((ROOT / "contracts/artemis-live-evidence.schema.json").read_text())
        sample = json.loads((ROOT / "samples/artemis-live-evidence.sample.json").read_text())

        required = set(schema["required"])
        expected = {
            "run_id",
            "app_build_commit",
            "device_ids",
            "glasses_connection_state",
            "audio_input_route",
            "audio_output_route",
            "dat_state",
            "frame_id",
            "frame_timestamp_ms",
            "frame_age_ms",
            "stt_partial_sequence",
            "final_transcript",
            "finalization_reason",
            "selected_brain",
            "selected_model",
            "model_latency_ms",
            "tts_engine",
            "first_response_ms",
            "end_to_end_ms",
            "response_text",
            "used_current_visual_context",
            "artifact_refs",
            "artifact_hashes",
            "pass",
            "evidence_class",
        }
        self.assertEqual(expected, required)
        self.assertTrue(required.issubset(sample))
        self.assertIn(
            sample["evidence_class"],
            schema["properties"]["evidence_class"]["enum"],
        )
        self.assertEqual(
            schema["properties"]["evidence_class"]["enum"],
            ["unit", "simulated", "replay", "component", "live_dat", "live_assistant", "golden"],
        )

    def test_latest_frame_schema_and_sample_cover_actual_frame_contract(self) -> None:
        schema = json.loads((ROOT / "contracts/artemis-latest-frame.schema.json").read_text())
        sample = json.loads((ROOT / "samples/artemis-latest-frame.sample.json").read_text())

        expected_required = {
            "frame_id",
            "source_timestamp_ms",
            "ingest_timestamp_ms",
            "frame_age_ms",
            "source_device",
            "width",
            "height",
            "mime_type",
            "content_hash",
            "scene_change_score",
            "queue_depth",
            "artifact_ref",
            "artifact_sha256",
        }
        self.assertEqual(expected_required, set(schema["required"]))
        self.assertTrue(expected_required.issubset(sample))
        self.assertEqual(sample["queue_depth"], 1)
        self.assertTrue(sample["artifact_ref"].startswith("/vision/frame/"))

    def test_vision_latest_requires_auth_and_returns_latest_frame_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            server = artemis_log_server.make_server(
                host="127.0.0.1",
                port=0,
                db_path=root / "events.sqlite3",
                vision_dir=root / "vision",
                vision_token="test-token",
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            host, port = server.server_address

            conn = HTTPConnection(host, port, timeout=5)
            conn.request("GET", "/vision/latest")
            response = conn.getresponse()
            response.read()
            self.assertEqual(response.status, 401)

            image_bytes = b"\xff\xd8\xff\xe0artemis-test-frame\xff\xd9"
            encoded = base64.b64encode(image_bytes).decode("ascii")
            payload = {
                "frame_id": 7,
                "source_timestamp_ms": int(time.time() * 1000) - 25,
                "source_device": "iphone-artemis",
                "width": 2,
                "height": 2,
                "mime_type": "image/jpeg",
                "image_base64": encoded,
            }
            conn.request(
                "POST",
                "/vision/frame",
                body=json.dumps(payload),
                headers={
                    "Authorization": "Bearer test-token",
                    "Content-Type": "application/json",
                },
            )
            response = conn.getresponse()
            body = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 201)
            self.assertEqual(body["frame_id"], 7)
            self.assertEqual(body["queue_depth"], 1)
            self.assertEqual(body["mime_type"], "image/jpeg")
            self.assertEqual(body["duplicate_content"], False)

            conn.request(
                "GET",
                "/vision/latest",
                headers={"Authorization": "Bearer test-token"},
            )
            response = conn.getresponse()
            latest = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 200)
            self.assertEqual(latest["frame_id"], 7)
            self.assertEqual(latest["source_device"], "iphone-artemis")
            self.assertEqual(latest["queue_depth"], 1)
            self.assertGreaterEqual(latest["frame_age_ms"], 0)
            self.assertEqual(latest["artifact_ref"], "/vision/frame/latest.jpg")
            self.assertNotIn("image_base64", latest)

            conn.request(
                "GET",
                latest["artifact_ref"],
                headers={"Authorization": "Bearer test-token"},
            )
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Content-Type"), "image/jpeg")
            self.assertEqual(response.read(), image_bytes)

            webcam_bytes = b"\xff\xd8\xff\xe0m1-webcam-frame\xff\xd9"
            webcam_payload = {
                **payload,
                "frame_id": 8,
                "source_timestamp_ms": int(time.time() * 1000) - 10,
                "source_device": "m1-alloco-webcam",
                "image_base64": base64.b64encode(webcam_bytes).decode("ascii"),
            }
            conn.request(
                "POST",
                "/vision/frame?stream=webcam",
                body=json.dumps(webcam_payload),
                headers={
                    "Authorization": "Bearer test-token",
                    "Content-Type": "application/json",
                },
            )
            response = conn.getresponse()
            webcam_latest = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 201)
            self.assertEqual(webcam_latest["source_device"], "m1-alloco-webcam")
            self.assertEqual(webcam_latest["artifact_ref"], "/vision/frame/webcam/latest.jpg")

            conn.request(
                "GET",
                "/vision/latest?stream=webcam",
                headers={"Authorization": "Bearer test-token"},
            )
            response = conn.getresponse()
            webcam_latest = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 200)
            self.assertEqual(webcam_latest["frame_id"], 8)

            conn.request(
                "GET",
                webcam_latest["artifact_ref"],
                headers={"Authorization": "Bearer test-token"},
            )
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), webcam_bytes)

            conn.request(
                "GET",
                "/vision/latest",
                headers={"Authorization": "Bearer test-token"},
            )
            response = conn.getresponse()
            meta_latest = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 200)
            self.assertEqual(meta_latest["frame_id"], 7)

    def test_stale_or_duplicate_frame_id_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = artemis_log_server.LatestFrameStore(root / "vision")
            payload = {
                "frame_id": 3,
                "source_timestamp_ms": 1_800_000_000_000,
                "source_device": "iphone-artemis",
                "width": 2,
                "height": 2,
                "mime_type": "image/jpeg",
                "image_base64": base64.b64encode(b"\xff\xd8one\xff\xd9").decode("ascii"),
            }
            store.store_frame(payload)
            with self.assertRaises(artemis_log_server.StaleFrameError):
                store.store_frame(dict(payload))

    def test_live_voice_keeps_stt_armed_across_processing_and_tts(self) -> None:
        source = (ROOT / "Artemis/Artemis/ArtemisApp.swift").read_text()

        self.assertIn("voice_turn_completed_stt_continues", source)
        self.assertIn("voice_stt_restart_after_tts_skipped_already_armed", source)

        turn_complete_start = source.index("func turnTakingDidCompleteTurn")
        turn_complete_end = source.index("func turnTakingDidTimeoutProcessing", turn_complete_start)
        turn_complete_body = source[turn_complete_start:turn_complete_end]
        before_calibration_branch = turn_complete_body.split("if sttCalibrationModeEnabled", 1)[0]
        self.assertNotIn("stopListening()", before_calibration_branch)

        restart_start = source.index("private func restartListeningAfterSpeechOutput")
        restart_end = source.index("func askBrain", restart_start)
        restart_body = source[restart_start:restart_end]
        self.assertIn("if wasListening || wasStarting", restart_body)
        self.assertIn("return", restart_body.split("if wasListening || wasStarting", 1)[1])

    def test_audio_level_vad_feeds_turn_taking_without_empty_turns(self) -> None:
        app_source = (ROOT / "Artemis/Artemis/ArtemisApp.swift").read_text()
        turn_source = (ROOT / "Artemis/Artemis/Core/TurnTakingManager.swift").read_text()

        self.assertIn("updateTurnTakingVADFromAudioLevel(peak: peak)", app_source)
        self.assertIn("voice_vad_speech_start", app_source)
        self.assertIn("voice_vad_speech_end", app_source)
        self.assertIn("turnTaking.onSpeechStart()", app_source)
        self.assertIn("turnTaking.onSpeechEnd()", app_source)

        self.assertIn("Ignoring empty turn completion", turn_source)
        self.assertIn("guard !trimmed.isEmpty", turn_source)

    def test_hud_voice_uses_private_glasses_route_after_display_start(self) -> None:
        voice_source = (ROOT / "Artemis/Artemis/HUDControl/HUDControlVoiceAnnouncer.swift").read_text()
        view_source = (ROOT / "Artemis/Artemis/HUDControl/HUDControlView.swift").read_text()

        self.assertIn("enablePrivateGlassesDuplexRoute()", voice_source)
        self.assertIn("route_mode=private_glasses_duplex", voice_source)

        display_start = view_source.index("await datSession.start()")
        monitor_speak = view_source.index('speakPendingVoiceLine(reason: "monitor_start")')
        self.assertLess(display_start, monitor_speak)

    def test_dat_display_smoke_is_real_and_model_free(self) -> None:
        source = (ROOT / "Artemis/Artemis/ArtemisApp.swift").read_text()

        branch_start = source.index('if arguments.contains("--run-dat-display-smoke")')
        branch_end = source.index('if arguments.contains("--run-live-golden-loop")', branch_start)
        branch = source[branch_start:branch_end]

        self.assertIn("self.startValidation()", branch)
        self.assertIn("displayHUDModeEnabled = true", branch)
        self.assertIn("liveGoldenModeEnabled = false", branch)
        self.assertIn("sentinelEnabled = false", branch)
        self.assertIn('"voice_enabled": false', branch)
        self.assertIn('"vision_inference_enabled": false', branch)
        self.assertIn('"model_api_calls": false', branch)
        self.assertNotIn("startVoiceBridge()", branch)
        self.assertNotIn("toggleLiveSentinel()", branch)

    def test_registered_dat_state_blocks_duplicate_registration(self) -> None:
        source = (ROOT / "Artemis/Artemis/ArtemisApp.swift").read_text()

        register_start = source.index("func registerWearables()")
        register_end = source.index("func unregisterWearables()", register_start)
        register_body = source[register_start:register_end]
        self.assertIn("Wearables.shared.registrationState != .registered", register_body)
        self.assertIn("registration request ignored", register_body)
        self.assertIn('.disabled(session.isDATRegistered)', source)


if __name__ == "__main__":
    unittest.main()
