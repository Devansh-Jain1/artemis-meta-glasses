# Artemis — Local AI + Meta Glasses

A sanitized, history-free source snapshot exploring phone-hosted intelligence for Meta
glasses: local visual context, speech, model routing, and a compact display HUD.
The iPhone hosts the models; the glasses supply camera/display surfaces through
Meta DAT. This repository is distinct from the separate phone-only
LocalArtemis project.

## What I built and investigated

- **Liquid AI visual sentinel:** LFM2.5-VL-450M through LeapSDK for lightweight
  visual context, with separate experiments involving the 1.6B variant. A sentinel
  identifies bounded scene context; it is not assumed capable of arbitrary text
  reading or general visual reasoning.
- **Phone-first orchestration:** a Gemma E2B text-reasoning path, local routing,
  voice activity detection, Apple speech recognition, and Kokoro ONNX speech
  output. Runtime availability and historical experiments are documented rather
  than presented as interchangeable, completed product features.
- **Wearable integration:** DAT registration and camera lifecycle, frame
  freshness, latest-frame-wins handling, and bounded HUD text for a small display.
- **Evaluation infrastructure:** repeatable recorded-video trials, fresh-process
  model comparisons, per-turn telemetry, and explicit evidence classes that
  separate component checks from a complete live spoken interaction.
- **Interaction engineering:** turn finalization, interruption and echo handling,
  streaming speech, cancellation, and visible failure states.

## Evidence, not a production claim

Private development receipts record historical live DAT frames reaching the
phone and LFM2.5-VL-450M processing selected frames. Raw logs and media are not
published in this snapshot.
That is **live camera/model component evidence**, not proof of a complete,
reliable glasses assistant. A rendered HUD or successful build is likewise not
proof of an attended optical or conversational test.

The historical baseline audit records missing end-to-end spoken-loop evidence.
No fresh hardware validation was performed while preparing this snapshot.
Archived prototypes and private development history are deliberately excluded.

## Architecture and privacy

The phone owns the immediate speech/vision loop. Optional Pi, Mac, cloud, or
Codex/Jarvis adapters are separate asynchronous paths; their presence does not
mean that every mode is local-only. Inspect the selected runtime, endpoint, and
permissions before enabling camera, microphone, telemetry, or off-device tools.
Personal media, model weights, credentials, and app registration material must
be provisioned privately rather than committed.

See the [publication notes](docs/PUBLICATION.md) and
[evidence contract](contracts/artemis-live-evidence.schema.json).

## Build and inspection

This is a development codebase, not a clean-machine release. Inspect source and
dependency declarations before building. A compatible Xcode/iOS setup, authorized
Meta SDK access and app registration, separately provisioned local models, and
physical hardware are required for the relevant integration tests. The pinned
dependencies and target settings, not older prose, define compatibility.

```sh
open Artemis/Artemis.xcodeproj
# Static architecture check; not a live-device validation:
python3 tools/artemis_live_golden_static_check.py
```

- `Artemis/` — iOS application and device/model integration.
- `contracts/` — evidence and integration contracts.
- `tools/` — preflight, benchmark, and diagnostic utilities.
- `docs/` — publication scope and validation limitations.
- `SNAPSHOT.json` — source revision, sanitization scope, and source-file hashes.

Meta registration, signing identity, associated domains, and telemetry endpoints
are blank or disabled. Private peer addresses and local developer paths are
replaced with examples. Model resources are deliberately absent. Supply your own
authorized configuration and assets before hardware testing; this is **not a
turnkey build or installable app**. The source includes a separately instrumented
Jarvis voice/bridge lane; its presence does not validate the full glasses loop.

## Rights and dependencies

Public source visibility is not a new open-source license grant. Third-party
code, SDKs, and model assets retain their respective licenses and access terms.
This is an independent personal project, not an official Meta, Google, or Liquid
AI product.
