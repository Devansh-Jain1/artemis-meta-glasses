import Combine
import Foundation

@MainActor
final class HUDControlViewModel: ObservableObject {
    @Published private(set) var payload: HUDControlDisplayPayload
    @Published private(set) var state: HUDControlState
    @Published private(set) var lastEvent: HUDControlEvent?
    @Published private(set) var lastActionResult: HUDControlActionResult?
    @Published private(set) var errorText: String?
    @Published var question: String

    private let client: HUDControlClient
    private var lastPayloadSignature = ""
    private var pendingVoiceLine: String?

    init(
        client: HUDControlClient,
        initialPayload: HUDControlDisplayPayload? = nil,
        question: String = "What should happen next?"
    ) {
        let initialPayload = initialPayload ?? HUDControlDisplayPayload.placeholder()
        self.client = client
        self.payload = initialPayload
        self.state = HUDControlStateMachine.initialState(rowCount: max(initialPayload.rowIDs.count, 0))
        self.question = question
    }

    var selectedRowID: String? {
        let ids = payload.rowIDs
        guard ids.indices.contains(state.focusedRowIndex) else { return payload.selectedID }
        return ids[state.focusedRowIndex]
    }

    var focusedAction: HUDControlActionKind {
        HUDControlStateMachine.actions[state.focusedActionIndex]
    }

    func refresh(announce: Bool = false, preserveFocus: Bool = false) async {
        do {
            let nextPayload = try await client.fetchDisplay()
            let nextSignature = payloadSignature(nextPayload)
            let previousSignature = lastPayloadSignature
            let previousState = state
            payload = nextPayload
            state = preserveFocus ? preservedState(previousState, rowCount: nextPayload.rowIDs.count) : HUDControlStateMachine.initialState(rowCount: nextPayload.rowIDs.count)
            lastPayloadSignature = nextSignature
            errorText = nil
            if announce {
                pendingVoiceLine = monitorVoiceLine(prefix: "Jarvis monitor online", payload: nextPayload)
            } else if !previousSignature.isEmpty && previousSignature != nextSignature {
                pendingVoiceLine = monitorVoiceLine(prefix: "Monitor changed", payload: nextPayload)
            }
        } catch {
            errorText = "HUD refresh failed: \(error.localizedDescription)"
            pendingVoiceLine = "HUD monitor refresh failed."
        }
    }

    func handle(_ input: HUDControlInputKind, source: HUDControlInputSource) async {
        let beforeRowID = selectedRowID
        let transition = HUDControlStateMachine.transition(
            state: state,
            input: input,
            focusedRowID: beforeRowID
        )
        state = transition.state

        let event = HUDControlStateMachine.event(
            source: source,
            input: input,
            rowID: selectedRowID ?? beforeRowID,
            action: focusedAction,
            result: transition.result,
            message: transition.actionToInvoke?.rawValue
        )
        lastEvent = event
        setStatusLine(statusLine(for: event))
        if let line = voiceLine(for: event) {
            pendingVoiceLine = line
        }
        await client.postInputEvent(event)

        guard let action = transition.actionToInvoke else { return }
        await invoke(action)
    }

    private func invoke(_ action: HUDControlActionKind) async {
        do {
            let result = try await client.invoke(
                action: action,
                targetID: selectedRowID,
                execute: action != .draft,
                question: question
            )
            lastActionResult = result
            errorText = nil
            setStatusLine(statusLine(for: result))
            pendingVoiceLine = result.voiceLine ?? statusLine(for: result)
        } catch {
            errorText = "HUD action failed: \(error.localizedDescription)"
            setStatusLine("ERR \(error.localizedDescription)")
            pendingVoiceLine = "HUD action failed."
        }
    }

    func consumeVoiceLine() -> String? {
        let line = pendingVoiceLine
        pendingVoiceLine = nil
        return line
    }

    private func statusLine(for event: HUDControlEvent) -> String {
        switch event.result {
        case .highlightChanged:
            return "\(event.inputKind.rawValue) \(event.focusedAction?.rawValue ?? "-")"
        case .draftConfirmationRequested:
            return "DRAFT confirm"
        case .draftConfirmed:
            return "DRAFT queued"
        case .actionInvoked:
            return "\(event.focusedAction?.rawValue ?? "ACTION") sent"
        case .blocked:
            return "Blocked"
        case .ignored:
            return "Ignored"
        }
    }

    private func voiceLine(for event: HUDControlEvent) -> String? {
        switch event.result {
        case .draftConfirmationRequested:
            return "Draft needs a second confirm before anything is queued."
        case .draftConfirmed:
            return nil
        case .blocked where event.inputKind == .back:
            return "Draft canceled."
        case .blocked:
            return "That HUD action is blocked."
        case .ignored:
            return nil
        case .highlightChanged, .actionInvoked:
            return nil
        }
    }

    private func statusLine(for result: HUDControlActionResult) -> String {
        if let error = result.error, !error.isEmpty {
            return "ERR \(error)"
        }
        let action = result.actionKind ?? "ACTION"
        return "\(action) \(result.status)"
    }

    private func setStatusLine(_ text: String) {
        var lines = payload.lines
        while lines.count < 2 {
            lines.append("")
        }
        lines[1] = trimStatusLine(text)
        payload.lines = lines
    }

    private func trimStatusLine(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 34 else { return collapsed }
        return String(collapsed.prefix(31)) + "..."
    }

    private func payloadSignature(_ payload: HUDControlDisplayPayload) -> String {
        ([payload.selectedID ?? ""] + payload.lines).joined(separator: "\u{1f}")
    }

    private func preservedState(_ previous: HUDControlState, rowCount: Int) -> HUDControlState {
        guard rowCount > 0 else { return .empty() }
        return HUDControlState(
            rowCount: rowCount,
            focusedRowIndex: min(max(previous.focusedRowIndex, 0), rowCount - 1),
            focusedActionIndex: min(max(previous.focusedActionIndex, 0), HUDControlStateMachine.actions.count - 1),
            mode: previous.mode == .blocked ? .rowFocus : previous.mode,
            pendingDraftRowID: previous.pendingDraftRowID
        )
    }

    private func monitorVoiceLine(prefix: String, payload: HUDControlDisplayPayload) -> String {
        let headline = trimVoice(payload.lines.first ?? "Codex HUD")
        let selected = selectedVoiceSummary(payload: payload)
        if selected.isEmpty {
            return "\(prefix). \(headline)."
        }
        return "\(prefix). \(headline). \(selected)"
    }

    private func selectedVoiceSummary(payload: HUDControlDisplayPayload) -> String {
        let firstRowLine = payload.lines.indices.contains(2) ? payload.lines[2] : ""
        let firstSubLine = payload.lines.indices.contains(3) ? payload.lines[3] : ""
        let summary = [firstRowLine, firstSubLine]
            .map { trimVoice($0) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        guard !summary.isEmpty else { return "" }
        return "Selected: \(summary)."
    }

    private func trimVoice(_ text: String, limit: Int = 140) -> String {
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

extension HUDControlDisplayPayload {
    var rowIDs: [String] {
        let ordered = actions.keys.sorted { lhs, rhs in
            if lhs == selectedID { return true }
            if rhs == selectedID { return false }
            return lhs < rhs
        }
        return ordered
    }
}
