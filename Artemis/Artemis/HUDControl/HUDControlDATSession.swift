import Combine
import Foundation
import MWDATCore
import MWDATDisplay

@MainActor
final class HUDControlDATSession: ObservableObject {
    @Published private(set) var statusText = "Glasses display idle"
    @Published private(set) var diagnostics: [String] = []

    private var deviceSession: DeviceSession?
    private var display: MWDATDisplay.Display?
    private var displayStateToken: AnyListenerToken?
    private var sessionErrorTask: Task<Void, Never>?
    private var inputHandler: ((HUDControlInputKind) async -> Void)?
    private var isStarting = false
    private var isSending = false
    private var pendingPayload: HUDControlDisplayPayload?
    private var pendingState: HUDControlState?

    func setInputHandler(_ handler: @escaping (HUDControlInputKind) async -> Void) {
        inputHandler = handler
    }

    func start() async {
        guard !isStarting, display == nil else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            emit("Starting display-only DAT session")
            await waitForDisplayEligibleDevice(timeoutSeconds: 10)

            let selector = try makeDeviceSelector()
            let session = try Wearables.shared.createSession(deviceSelector: selector)
            deviceSession = session

            let stateStream = session.stateStream()
            let errorStream = session.errorStream()
            try session.start()
            try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
            sessionErrorTask = observeSessionErrors(session)

            let newDisplay = try session.addDisplay()
            display = newDisplay
            displayStateToken = newDisplay.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.emit("Display state \(String(describing: state))")
                    if state == .started {
                        await self?.flushPendingDisplay()
                    }
                }
            }
            await newDisplay.start()
            emit("Display start requested")
        } catch {
            emit("Display session failed: \(describeDATRuntimeError(error))")
            stop()
        }
    }

    func send(payload: HUDControlDisplayPayload, state: HUDControlState) async {
        pendingPayload = payload
        pendingState = state
        await flushPendingDisplay()
    }

    private func flushPendingDisplay() async {
        guard !isSending else { return }
        guard let display else {
            emit("Display send skipped: no display session")
            return
        }
        guard display.state == .started else {
            emit("Display send skipped: state \(String(describing: display.state))")
            return
        }
        guard let payload = pendingPayload, let state = pendingState else { return }
        pendingPayload = nil
        pendingState = nil

        isSending = true
        defer { isSending = false }
        do {
            try await display.send(makeView(payload: payload, state: state))
            emit("HUD display sent")
        } catch {
            emit("HUD display send failed: \(error.localizedDescription) (\(String(describing: error)))")
        }
    }

    func stop() {
        let activeDisplay = display
        displayStateToken = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        display = nil
        deviceSession?.stop()
        deviceSession = nil
        if let activeDisplay {
            Task {
                await activeDisplay.stop()
            }
        }
        emit("Display session stopped")
    }

    private func makeView(payload: HUDControlDisplayPayload, state: HUDControlState) -> MWDATDisplay.FlexBox {
        let selectedLine = selectedDisplayLineIndex(payload: payload, state: state)
        let safeLineCount = payload.viewport?.safeLines ?? 9
        let displayLines = Array(payload.lines.prefix(max(1, safeLineCount)))
        let focusedAction = HUDControlStateMachine.actions[
            min(max(state.focusedActionIndex, 0), HUDControlStateMachine.actions.count - 1)
        ]

        return MWDATDisplay.FlexBox(direction: .column, spacing: 8, crossAlignment: .stretch) {
            MWDATDisplay.FlexBox(direction: .row, spacing: 6, alignment: .center, crossAlignment: .center) {
                MWDATDisplay.Text("CODEX HUD", style: .heading)
                MWDATDisplay.Text(state.mode == .confirmDraft ? "CONFIRM DRAFT" : focusedAction.rawValue, style: .meta, color: .secondary)
            }

            MWDATDisplay.FlexBox(direction: .column, spacing: 3, crossAlignment: .stretch) {
                ForEachDisplayLines(lines: displayLines, selectedLine: selectedLine)
            }

            MWDATDisplay.FlexBox(direction: .row, spacing: 6, alignment: .center, crossAlignment: .center) {
                MWDATDisplay.Button(label: "ROW", style: .secondary) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.dispatch(.nextRow)
                    }
                }
                MWDATDisplay.Button(label: "MODE", style: .secondary) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.dispatch(.nextAction)
                    }
                }
                MWDATDisplay.Button(label: state.mode == .confirmDraft ? "CONFIRM" : "GO", style: .primary) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.dispatch(.select)
                    }
                }
                MWDATDisplay.Button(label: "BACK", style: .outline) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.dispatch(.back)
                    }
                }
            }
        }
        .padding(14)
        .background(.card)
    }

    private func ForEachDisplayLines(lines: [String], selectedLine: Int) -> MWDATDisplay.FlexBox {
        MWDATDisplay.FlexBox(direction: .column, spacing: 3, crossAlignment: .stretch) {
            for (index, line) in lines.enumerated() {
                MWDATDisplay.Text(
                    trim(line.replacingOccurrences(of: "STEER", with: "DRAFT"), limit: 44),
                    style: index == selectedLine ? .body : .meta,
                    color: index == selectedLine ? .primary : .secondary
                )
            }
        }
    }

    private func dispatch(_ input: HUDControlInputKind) async {
        guard let inputHandler else { return }
        emit("Glasses input \(input.rawValue)")
        await inputHandler(input)
    }

    private func selectedDisplayLineIndex(payload: HUDControlDisplayPayload, state: HUDControlState) -> Int {
        let rowBase = 2 + state.focusedRowIndex * 2
        return min(max(rowBase, 0), max(payload.lines.count - 1, 0))
    }

    private func trim(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed.isEmpty ? "-" : collapsed }
        return String(collapsed.prefix(limit - 3)) + "..."
    }

    private func waitForDisplayEligibleDevice(timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastSummary = ""
        while Date() < deadline {
            let snapshot = currentDisplayEligibilitySnapshot()
            if snapshot.eligible {
                emit("Display device eligible: \(snapshot.summary)")
                return
            }
            if snapshot.summary != lastSummary {
                emit("Waiting for display device: \(snapshot.summary)")
                lastSummary = snapshot.summary
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        emit("Display eligibility wait timed out: \(currentDisplayEligibilitySnapshot().summary)")
    }

    private func currentDisplayEligibilitySnapshot() -> (eligible: Bool, summary: String) {
        let devices = Wearables.shared.devices.compactMap { deviceID -> (Bool, String)? in
            guard let device = Wearables.shared.deviceForIdentifier(deviceID) else { return nil }
            let isEligible = device.linkState == .connected
                && device.compatibility() == .compatible
                && device.supportsDisplay()
            return (
                isEligible,
                "\(String(describing: deviceID)) | \(device.nameOrId()) | link=\(String(describing: device.linkState)) | compat=\(String(describing: device.compatibility())) | display=\(device.supportsDisplay())"
            )
        }
        guard !devices.isEmpty else {
            return (false, "No DAT devices visible")
        }
        return (
            devices.contains { $0.0 },
            devices.map(\.1).joined(separator: " || ")
        )
    }

    private func makeDeviceSelector() throws -> any DeviceSelector {
        if let deviceID = Wearables.shared.devices.first(where: { deviceID in
            guard let device = Wearables.shared.deviceForIdentifier(deviceID) else { return false }
            return device.linkState == .connected
                && device.compatibility() == .compatible
                && device.supportsDisplay()
        }) {
            emit("Using display-capable DAT device selector: \(String(describing: deviceID))")
            return SpecificDeviceSelector(device: deviceID)
        }
        emit("No display-capable specific device found; using auto selector")
        return AutoDeviceSelector(wearables: Wearables.shared)
    }

    private func waitForSessionStart(
        stateStream: AsyncStream<DeviceSessionState>,
        errorStream: AsyncStream<DeviceSessionError>
    ) async throws {
        if deviceSession?.state == .started { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in stateStream {
                    if state == .started { return }
                    if state == .stopped {
                        throw DeviceSessionError.unexpectedError(description: "The session stopped before starting.")
                    }
                }
            }
            group.addTask {
                for await error in errorStream {
                    throw error
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func observeSessionErrors(_ session: DeviceSession) -> Task<Void, Never> {
        Task { [weak self] in
            for await error in session.errorStream() {
                await MainActor.run {
                    self?.emit("Display session error: \(describeDATRuntimeError(error))")
                }
            }
        }
    }

    private func emit(_ message: String) {
        statusText = message
        diagnostics.append(message)
        if diagnostics.count > 8 {
            diagnostics.removeFirst(diagnostics.count - 8)
        }
        NSLog("[HUDControlDAT] %@", message)
        ArtemisRemoteLogSink.send("[HUDControlDAT] \(message)")
    }
}
