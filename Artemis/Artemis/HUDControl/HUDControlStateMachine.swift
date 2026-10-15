import Foundation

enum HUDControlFocusMode: String, Codable, Equatable {
    case rowFocus
    case actionFocus
    case confirmDraft
    case blocked
}

enum HUDControlActionKind: String, Codable, CaseIterable, Equatable {
    case open = "OPEN"
    case ask = "ASK"
    case draft = "DRAFT"
}

enum HUDControlInputKind: String, Codable, Equatable {
    case nextRow
    case previousRow
    case nextAction
    case previousAction
    case select
    case back
    case longPress
}

enum HUDControlInputSource: String, Codable, Equatable {
    case neuralBand = "neural_band"
    case touchpad
    case phone
    case keyboard
    case unknown
}

enum HUDControlInputResult: String, Codable, Equatable {
    case highlightChanged = "highlight_changed"
    case actionInvoked = "action_invoked"
    case draftConfirmationRequested = "draft_confirmation_requested"
    case draftConfirmed = "draft_confirmed"
    case ignored
    case blocked
}

struct HUDControlEvent: Codable, Equatable {
    var timestamp: Date
    var surface: String
    var inputSource: HUDControlInputSource
    var inputKind: HUDControlInputKind
    var focusedRowID: String?
    var focusedAction: HUDControlActionKind?
    var result: HUDControlInputResult
    var message: String?
}

struct HUDControlState: Codable, Equatable {
    var rowCount: Int
    var focusedRowIndex: Int
    var focusedActionIndex: Int
    var mode: HUDControlFocusMode
    var pendingDraftRowID: String?

    static func empty() -> HUDControlState {
        HUDControlState(
            rowCount: 0,
            focusedRowIndex: 0,
            focusedActionIndex: 0,
            mode: .blocked,
            pendingDraftRowID: nil
        )
    }
}

struct HUDControlTransition: Equatable {
    var state: HUDControlState
    var result: HUDControlInputResult
    var actionToInvoke: HUDControlActionKind?
}

enum HUDControlStateMachine {
    static let actions: [HUDControlActionKind] = [.open, .ask, .draft]

    static func initialState(rowCount: Int) -> HUDControlState {
        guard rowCount > 0 else { return .empty() }
        return HUDControlState(
            rowCount: rowCount,
            focusedRowIndex: 0,
            focusedActionIndex: 1,
            mode: .rowFocus,
            pendingDraftRowID: nil
        )
    }

    static func transition(
        state: HUDControlState,
        input: HUDControlInputKind,
        focusedRowID: String?
    ) -> HUDControlTransition {
        guard state.rowCount > 0 else {
            return HUDControlTransition(state: .empty(), result: .blocked, actionToInvoke: nil)
        }

        var next = normalized(state)

        if next.mode == .confirmDraft {
            switch input {
            case .select, .longPress:
                next.mode = .actionFocus
                next.pendingDraftRowID = nil
                return HUDControlTransition(state: next, result: .draftConfirmed, actionToInvoke: .draft)
            case .back, .previousAction, .nextAction, .nextRow, .previousRow:
                next.mode = .actionFocus
                next.pendingDraftRowID = nil
                return HUDControlTransition(state: next, result: .blocked, actionToInvoke: nil)
            }
        }

        switch input {
        case .nextRow:
            next.focusedRowIndex = (next.focusedRowIndex + 1) % next.rowCount
            next.mode = .rowFocus
            return HUDControlTransition(state: next, result: .highlightChanged, actionToInvoke: nil)

        case .previousRow:
            next.focusedRowIndex = (next.focusedRowIndex - 1 + next.rowCount) % next.rowCount
            next.mode = .rowFocus
            return HUDControlTransition(state: next, result: .highlightChanged, actionToInvoke: nil)

        case .nextAction:
            next.focusedActionIndex = (next.focusedActionIndex + 1) % actions.count
            next.mode = .actionFocus
            return HUDControlTransition(state: next, result: .highlightChanged, actionToInvoke: nil)

        case .previousAction:
            next.focusedActionIndex = (next.focusedActionIndex - 1 + actions.count) % actions.count
            next.mode = .actionFocus
            return HUDControlTransition(state: next, result: .highlightChanged, actionToInvoke: nil)

        case .back:
            next.mode = next.mode == .actionFocus ? .rowFocus : .rowFocus
            next.pendingDraftRowID = nil
            return HUDControlTransition(state: next, result: .highlightChanged, actionToInvoke: nil)

        case .select:
            let action = actions[next.focusedActionIndex]
            if action == .draft {
                next.mode = .confirmDraft
                next.pendingDraftRowID = focusedRowID
                return HUDControlTransition(
                    state: next,
                    result: .draftConfirmationRequested,
                    actionToInvoke: nil
                )
            }
            next.mode = .actionFocus
            return HUDControlTransition(state: next, result: .actionInvoked, actionToInvoke: action)

        case .longPress:
            return HUDControlTransition(state: next, result: .ignored, actionToInvoke: nil)
        }
    }

    static func event(
        source: HUDControlInputSource,
        input: HUDControlInputKind,
        rowID: String?,
        action: HUDControlActionKind?,
        result: HUDControlInputResult,
        message: String? = nil,
        now: Date = Date()
    ) -> HUDControlEvent {
        HUDControlEvent(
            timestamp: now,
            surface: "glasses_display",
            inputSource: source,
            inputKind: input,
            focusedRowID: rowID,
            focusedAction: action,
            result: result,
            message: message
        )
    }

    private static func normalized(_ state: HUDControlState) -> HUDControlState {
        var copy = state
        copy.focusedRowIndex = min(max(copy.focusedRowIndex, 0), max(copy.rowCount - 1, 0))
        copy.focusedActionIndex = min(max(copy.focusedActionIndex, 0), max(actions.count - 1, 0))
        return copy
    }
}
