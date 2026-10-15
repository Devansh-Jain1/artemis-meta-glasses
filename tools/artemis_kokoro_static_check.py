#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Artemis" / "Artemis" / "ArtemisApp.swift"
SWIFT_ROOT = ROOT / "Artemis" / "Artemis"

source = APP.read_text()
all_swift = "\n".join(path.read_text() for path in SWIFT_ROOT.rglob("*.swift"))
errors: list[str] = []

if "@Published var selectedSpeechEngine: SpeechOutputEngine = .kokoroLocal" not in source:
    errors.append("Artemis must default live voice output to Kokoro, not Apple TTS.")

if re.search(r"case \.kokoroLocal\b[^\n]*:\s*\n\s*return false", source):
    errors.append("Kokoro availability is hard-coded false.")

guard_block = re.search(r"guard engine\.isAvailable else \{(?P<body>.*?)\n\s*\}", source, re.S)
if guard_block and "speakWithApple" in guard_block.group("body"):
    errors.append("Unavailable Kokoro/Supertonic must not silently fall back to Apple TTS.")

if "import OnnxRuntimeBindings" not in all_swift:
    errors.append("Native Kokoro ONNX path must import OnnxRuntimeBindings.")

if "ORTSession(" not in all_swift or 'forResource: "kokoro"' not in all_swift:
    errors.append("Kokoro ONNX model is not wired through ORTSession.")

if "KokoroTTS(" in all_swift or "NpyzReader.read" in all_swift:
    errors.append("Live Kokoro must not use the known-bad KokoroSwift safetensors/npz path.")

if '"af_bella"' not in all_swift:
    errors.append("Kokoro must use the approved ONNX af_bella voice.")

if "private let brain = LocalBrainService()" in source or "brain.respond(" in source:
    errors.append("Live/golden Artemis must not route user turns through LocalBrainService.")

if "private let perception = LocalPerceptionService()" in source or "perception.analyze(" in source:
    errors.append("Live/golden Artemis must not use LocalPerceptionService for semantic vision.")

if re.search(r'let\s+greeting\s*=\s*"Hi Devansh', source):
    errors.append("Startup greeting must be routed through the real brain/router, not a hardcoded TTS phrase.")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)

print("PASS: Artemis Kokoro path is native and Apple fallback is blocked.")
