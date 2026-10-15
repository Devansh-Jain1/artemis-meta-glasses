import SwiftUI

struct HUDControlView: View {
    @StateObject private var model: HUDControlViewModel
    @StateObject private var datSession = HUDControlDATSession()
    @StateObject private var voice = HUDControlVoiceAnnouncer()

    init(baseURL: URL) {
        _model = StateObject(wrappedValue: HUDControlViewModel(client: HUDControlClient(baseURL: baseURL)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            displayLines
            actionRail
            datStatus
            voiceStatus
            glassesInputStatus
            eventFooter
        }
        .padding(16)
        .background(Color.black)
        .foregroundStyle(Color.white)
        .task {
            await model.refresh(announce: true)
            datSession.setInputHandler { input in
                await model.handle(input, source: .neuralBand)
                speakPendingVoiceLine(reason: "glasses_input")
                await datSession.send(payload: model.payload, state: model.state)
            }
            await datSession.start()
            await datSession.send(payload: model.payload, state: model.state)
            speakPendingVoiceLine(reason: "monitor_start")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await model.refresh(preserveFocus: true)
                speakPendingVoiceLine(reason: "monitor_update")
                await datSession.send(payload: model.payload, state: model.state)
            }
        }
        .onDisappear {
            datSession.stop()
            voice.stop()
        }
    }

    private var header: some View {
        HStack {
            Text("HUD Control")
                .font(.headline)
            Spacer()
            Text("glasses input only")
                .font(.caption)
                .foregroundStyle(Color.gray)
        }
    }

    private var displayLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.payload.lines.enumerated()), id: \.offset) { index, line in
                Text(line.replacingOccurrences(of: "STEER", with: "DRAFT"))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(index == selectedDisplayLineIndex ? Color.green : Color.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 256, alignment: .leading)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionRail: some View {
        HStack(spacing: 10) {
            ForEach(HUDControlStateMachine.actions, id: \.rawValue) { action in
                Text(action.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(action == model.focusedAction ? Color.green : Color(white: 0.18))
                    .foregroundStyle(action == model.focusedAction ? Color.black : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .accessibilityIdentifier("hudControlActionRail")
    }

    private var glassesInputStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for glasses input")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.gray)
            Text("Neural Band / glasses events only. Phone buttons are intentionally not exposed.")
                .font(.caption)
                .foregroundStyle(Color.gray)
            if model.state.mode == .confirmDraft {
                Text("DRAFT requires confirmation. Select or Hold again to confirm draft.")
                    .font(.caption)
                    .foregroundStyle(Color.yellow)
            }
        }
        .accessibilityIdentifier("hudControlGlassesInputStatus")
    }

    private var voiceStatus: some View {
        Text(voice.statusText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.cyan)
            .accessibilityIdentifier("hudControlVoiceStatus")
    }

    private var datStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(datSession.statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.green)
            ForEach(Array(datSession.diagnostics.suffix(2).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(Color.gray)
            }
        }
        .accessibilityIdentifier("hudControlDATStatus")
    }

    private var eventFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let event = model.lastEvent {
                Text("\(event.inputKind.rawValue) -> \(event.result.rawValue)")
                    .font(.caption)
                    .foregroundStyle(Color.gray)
            }
            if let result = model.lastActionResult {
                Text("Action: \(result.actionKind ?? "?") \(result.status)")
                    .font(.caption)
                    .foregroundStyle(Color.gray)
            }
            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }

    private var selectedDisplayLineIndex: Int {
        let rowBase = 2 + model.state.focusedRowIndex * 2
        return min(max(rowBase, 0), max(model.payload.lines.count - 1, 0))
    }

    private func speakPendingVoiceLine(reason: String) {
        guard let line = model.consumeVoiceLine() else { return }
        voice.speak(line, reason: reason)
    }
}

#Preview {
    HUDControlView(baseURL: URL(string: "http://127.0.0.1:8788")!)
}
