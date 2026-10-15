import Foundation
#if os(iOS)
import AVFoundation
#endif

enum ArtemisAudioRouteActivationError: LocalizedError {
    case routeNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case let .routeNotAllowed(reason):
            reason
        }
    }
}

struct ArtemisAudioRouteEndpoint: Equatable, Sendable {
    let portType: String
    let portName: String
}

struct ArtemisAudioRouteDecision: Equatable, Sendable {
    let isAllowed: Bool
    let reason: String
}

enum ArtemisAdaptiveAudioTarget: String, Equatable, Sendable {
    case bose
    case metaGlasses = "meta_glasses"
    case iPhone = "iphone"
    case unsupported
}

struct ArtemisAdaptiveAudioSelection: Equatable, Sendable {
    let target: ArtemisAdaptiveAudioTarget
    let preferredInput: ArtemisAudioRouteEndpoint?
    let reason: String
}

struct ArtemisAdaptiveAudioEvaluation: Equatable, Sendable {
    let desired: ArtemisAdaptiveAudioSelection
    let currentOutputTarget: ArtemisAdaptiveAudioTarget
    let requiresReconfiguration: Bool
}

enum ArtemisJarvisAudioSessionProfile: String, Equatable, Sendable {
    case builtInSpeaker = "built_in_speaker"
    case callFree = "call_free"
    case adaptiveHFP = "adaptive_hfp"
}

struct ArtemisJarvisAudioLaunchSelection: Equatable, Sendable {
    let profile: ArtemisJarvisAudioSessionProfile
    let hfpMicrophoneAuthorized: Bool
    let reason: String
}

struct ArtemisJarvisAudioLaunchPolicy: Equatable, Sendable {
    static let hfpMicrophoneFlag = "--allow-hfp-microphone"

    private let jarvisLaunchArguments = [
        "--run-display-hud-coexistence",
        "--run-jarvis-local-gemma-loop",
        "--run-jarvis-codex-bridge-loop",
        "--run-live-golden-loop",
        "--run-jarvis-nano-bridge"
    ]

    func selection(arguments: [String]) -> ArtemisJarvisAudioLaunchSelection {
        let isJarvisRun = jarvisLaunchArguments.contains(where: arguments.contains)
        guard isJarvisRun else {
            return ArtemisJarvisAudioLaunchSelection(
                profile: .builtInSpeaker,
                hfpMicrophoneAuthorized: false,
                reason: "No Jarvis/glasses launch mode is active."
            )
        }

        let hfpMicrophoneAuthorized = arguments.contains(Self.hfpMicrophoneFlag)
        if hfpMicrophoneAuthorized {
            return ArtemisJarvisAudioLaunchSelection(
                profile: .adaptiveHFP,
                hfpMicrophoneAuthorized: true,
                reason: "The launch explicitly authorized a Bluetooth HFP microphone."
            )
        }

        return ArtemisJarvisAudioLaunchSelection(
            profile: .callFree,
            hfpMicrophoneAuthorized: false,
            reason: "Jarvis defaults to iPhone microphone plus A2DP or iPhone speaker to prevent a Bluetooth call profile."
        )
    }
}

struct ArtemisAdaptiveAudioRoutePolicy: Equatable, Sendable {
    private let boseNameFragments = ["bose", "qc ultra", "quietcomfort"]
    private let metaNameFragments = [
        "meta rb",
        "ray-ban",
        "rayban",
        "meta display",
        "rb display"
    ]

    static let jarvis = ArtemisAdaptiveAudioRoutePolicy()

    func selection(
        availableInputs: [ArtemisAudioRouteEndpoint]
    ) -> ArtemisAdaptiveAudioSelection {
        if let bose = availableInputs.first(where: { target(for: $0) == .bose }) {
            return ArtemisAdaptiveAudioSelection(
                target: .bose,
                preferredInput: bose,
                reason: "Bose duplex route is available and has highest priority."
            )
        }
        if let glasses = availableInputs.first(where: { target(for: $0) == .metaGlasses }) {
            return ArtemisAdaptiveAudioSelection(
                target: .metaGlasses,
                preferredInput: glasses,
                reason: "Meta glasses duplex route is the first available fallback."
            )
        }
        if let builtIn = availableInputs.first(where: { target(for: $0) == .iPhone }) {
            return ArtemisAdaptiveAudioSelection(
                target: .iPhone,
                preferredInput: builtIn,
                reason: "iPhone microphone and speaker are the last-resort duplex route."
            )
        }
        return ArtemisAdaptiveAudioSelection(
            target: .unsupported,
            preferredInput: nil,
            reason: "No Bose, Meta glasses, or iPhone microphone route is available."
        )
    }

    func evaluation(
        outputs: [ArtemisAudioRouteEndpoint],
        availableInputs: [ArtemisAudioRouteEndpoint]
    ) -> ArtemisAdaptiveAudioEvaluation {
        let desired = selection(availableInputs: availableInputs)
        let current = outputs.first.map(target(for:)) ?? .unsupported
        return ArtemisAdaptiveAudioEvaluation(
            desired: desired,
            currentOutputTarget: current,
            requiresReconfiguration: desired.target != .unsupported && desired.target != current
        )
    }

    func target(for endpoint: ArtemisAudioRouteEndpoint) -> ArtemisAdaptiveAudioTarget {
        let name = endpoint.portName.lowercased()
        if boseNameFragments.contains(where: name.contains) {
            return .bose
        }
        if metaNameFragments.contains(where: name.contains) {
            return .metaGlasses
        }
        let portType = endpoint.portType.lowercased()
        if portType.contains("builtin")
            || portType == "speaker"
            || portType == "receiver"
            || name.contains("iphone") {
            return .iPhone
        }
        return .unsupported
    }
}

struct ArtemisAdaptiveAudioActivation: Equatable, Sendable {
    let target: ArtemisAdaptiveAudioTarget
    let routeDescription: String
}

struct ArtemisAudioRoutePolicy: Equatable, Sendable {
    let allowedNameFragments: [String]
    let blockedNameFragments: [String]

    static let metaGlassesOnly = ArtemisAudioRoutePolicy(
        allowedNameFragments: [
            "meta rb",
            "ray-ban",
            "rayban",
            "meta display",
            "rb display"
        ],
        blockedNameFragments: [
            "airpods",
            "beats",
            "bose",
            "headphone",
            "headphones",
            "qc ultra",
            "sony"
        ]
    )

    func decision(for outputs: [ArtemisAudioRouteEndpoint]) -> ArtemisAudioRouteDecision {
        guard !outputs.isEmpty else {
            return ArtemisAudioRouteDecision(
                isAllowed: false,
                reason: "No active audio output route."
            )
        }

        let routeDescription = outputs
            .map { "\($0.portType):\($0.portName)" }
            .joined(separator: ", ")
        let routeNames = outputs.map { $0.portName.lowercased() }

        if let blocked = routeNames.first(where: { name in
            blockedNameFragments.contains { fragment in name.contains(fragment) }
        }) {
            return ArtemisAudioRouteDecision(
                isAllowed: false,
                reason: "Blocked private Artemis audio route: \(routeDescription). Matched disallowed output '\(blocked)'."
            )
        }

        let hasAllowedOutput = routeNames.contains { name in
            allowedNameFragments.contains { fragment in name.contains(fragment) }
        }
        guard hasAllowedOutput else {
            return ArtemisAudioRouteDecision(
                isAllowed: false,
                reason: "Private Artemis audio requires Meta/Ray-Ban glasses output; active route is \(routeDescription)."
            )
        }

        return ArtemisAudioRouteDecision(
            isAllowed: true,
            reason: "Private Artemis audio route confirmed: \(routeDescription)."
        )
    }

    func preferredInput(from inputs: [ArtemisAudioRouteEndpoint]) -> ArtemisAudioRouteEndpoint? {
        inputs.first { endpoint in
            let name = endpoint.portName.lowercased()
            guard !blockedNameFragments.contains(where: { name.contains($0) }) else {
                return false
            }
            return allowedNameFragments.contains(where: { name.contains($0) })
        }
    }

    static func describeRouteCandidates(
        outputs: [ArtemisAudioRouteEndpoint],
        availableInputs: [ArtemisAudioRouteEndpoint]
    ) -> String {
        let outputDescription = describe(endpoints: outputs)
        let inputDescription = describe(endpoints: availableInputs)
        return "outputs=[\(outputDescription)] availableInputs=[\(inputDescription)]"
    }

    #if os(iOS)
    static func activateAdaptiveJarvisDuplexSession(
        resetActiveSession: Bool
    ) throws -> ArtemisAdaptiveAudioActivation {
        let session = AVAudioSession.sharedInstance()
        let policy = ArtemisAdaptiveAudioRoutePolicy.jarvis

        if resetActiveSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        // A single voiceChat route keeps capture and playback on one endpoint.
        // Do not mix with other outputs: Bose, glasses, and iPhone are fallbacks,
        // never simultaneous speakers.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP]
        )
        try session.setActive(true)
        Thread.sleep(forTimeInterval: 0.10)

        let selection = policy.selection(availableInputs: availableInputEndpoints(session))
        guard let preferredInput = selection.preferredInput else {
            throw ArtemisAudioRouteActivationError.routeNotAllowed(
                "\(selection.reason) \(describeCurrentAudioRoute(session))"
            )
        }

        guard let input = session.availableInputs?.first(where: {
            $0.portType.rawValue == preferredInput.portType && $0.portName == preferredInput.portName
        }) else {
            throw ArtemisAudioRouteActivationError.routeNotAllowed(
                "Selected adaptive input disappeared before activation: \(preferredInput.portType):\(preferredInput.portName)."
            )
        }

        try session.setPreferredInput(input)
        try session.setActive(true)
        try session.setPreferredInput(input)
        if selection.target == .iPhone {
            try session.overrideOutputAudioPort(.speaker)
        } else {
            try session.overrideOutputAudioPort(.none)
        }
        Thread.sleep(forTimeInterval: 0.25)

        let evaluation = policy.evaluation(
            outputs: currentOutputEndpoints(session),
            availableInputs: availableInputEndpoints(session)
        )
        guard evaluation.currentOutputTarget == selection.target else {
            throw ArtemisAudioRouteActivationError.routeNotAllowed(
                "Adaptive audio selected \(selection.target.rawValue), but iOS activated \(evaluation.currentOutputTarget.rawValue). \(describeCurrentAudioRoute(session))"
            )
        }

        return ArtemisAdaptiveAudioActivation(
            target: selection.target,
            routeDescription: describeCurrentAudioRoute(session)
        )
    }

    static func activateMetaGlassesDuplexSession(resetActiveSession: Bool) throws -> String {
        let session = AVAudioSession.sharedInstance()
        let policy = ArtemisAudioRoutePolicy.metaGlassesOnly

        if resetActiveSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .mixWithOthers]
        )

        var preferredInput = matchingPreferredInput(in: session, policy: policy)
        if preferredInput == nil {
            try session.setActive(true)
            Thread.sleep(forTimeInterval: 0.10)
            preferredInput = matchingPreferredInput(in: session, policy: policy)
        }

        guard let preferredInput else {
            throw ArtemisAudioRouteActivationError.routeNotAllowed(
                "Private Artemis audio requires Meta/Ray-Ban glasses input. \(describeCurrentAudioRoute(session))"
            )
        }

        try session.setPreferredInput(preferredInput)
        try session.setActive(true)
        try session.setPreferredInput(preferredInput)
        try? session.overrideOutputAudioPort(.none)
        Thread.sleep(forTimeInterval: 0.25)

        var decision = policy.decision(for: currentOutputEndpoints(session))
        if !decision.isAllowed {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .mixWithOthers]
            )
            try session.setPreferredInput(preferredInput)
            try session.setActive(true)
            try session.setPreferredInput(preferredInput)
            try? session.overrideOutputAudioPort(.none)
            Thread.sleep(forTimeInterval: 0.35)
            decision = policy.decision(for: currentOutputEndpoints(session))
        }

        guard decision.isAllowed else {
            throw ArtemisAudioRouteActivationError.routeNotAllowed(
                "\(decision.reason) Requested preferred input \(preferredInput.portType.rawValue):\(preferredInput.portName). \(describeCurrentAudioRoute(session))"
            )
        }

        return describeCurrentAudioRoute(session)
    }

    static func describeCurrentAudioRoute(_ session: AVAudioSession = .sharedInstance()) -> String {
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        return "inputs=[\(inputs.joined(separator: ","))] \(describeRouteCandidates(outputs: currentOutputEndpoints(session), availableInputs: availableInputEndpoints(session)))"
    }

    private static func matchingPreferredInput(
        in session: AVAudioSession,
        policy: ArtemisAudioRoutePolicy
    ) -> AVAudioSessionPortDescription? {
        guard let preferredInput = policy.preferredInput(from: availableInputEndpoints(session)) else {
            return nil
        }
        return session.availableInputs?.first {
            $0.portType.rawValue == preferredInput.portType && $0.portName == preferredInput.portName
        }
    }

    private static func currentOutputEndpoints(_ session: AVAudioSession) -> [ArtemisAudioRouteEndpoint] {
        session.currentRoute.outputs.map { output in
            ArtemisAudioRouteEndpoint(
                portType: output.portType.rawValue,
                portName: output.portName
            )
        }
    }

    private static func availableInputEndpoints(_ session: AVAudioSession) -> [ArtemisAudioRouteEndpoint] {
        (session.availableInputs ?? []).map { input in
            ArtemisAudioRouteEndpoint(
                portType: input.portType.rawValue,
                portName: input.portName
            )
        }
    }
    #endif

    private static func describe(endpoints: [ArtemisAudioRouteEndpoint]) -> String {
        if endpoints.isEmpty {
            return "none"
        }
        return endpoints
            .map { "\($0.portType):\($0.portName)" }
            .joined(separator: ",")
    }
}
