import Foundation

struct HUDControlDisplayPayload: Codable, Equatable {
    var schemaVersion: String
    var generatedAt: String?
    var lines: [String]
    var selectedID: String?
    var viewport: HUDControlViewport?
    var actions: [String: HUDControlActionSet]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case lines
        case selectedID = "selected_id"
        case viewport
        case actions
    }

    static func placeholder() -> HUDControlDisplayPayload {
        HUDControlDisplayPayload(
            schemaVersion: "hud.display_payload.v0",
            generatedAt: nil,
            lines: [
                "CODEX 48h: 0",
                "",
                "No HUD server",
                "",
                "OPEN   ASK   DRAFT"
            ],
            selectedID: nil,
            viewport: HUDControlViewport(width: 512, height: 512, safeLines: 9),
            actions: [:]
        )
    }
}

struct HUDControlViewport: Codable, Equatable {
    var width: Int
    var height: Int
    var safeLines: Int

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case safeLines = "safe_lines"
    }
}

struct HUDControlActionSet: Codable, Equatable {
    var open: HUDControlActionHandle?
    var ask: HUDControlActionHandle?
    var steer: HUDControlActionHandle?
}

struct HUDControlActionHandle: Codable, Equatable {
    var kind: String
    var protocolName: String?
    var command: String?
    var safety: String?
    var targetDevice: String?
    var targetID: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case protocolName = "protocol"
        case command
        case safety
        case targetDevice = "target_device"
        case targetID = "target_id"
    }
}

struct HUDControlActionResult: Codable, Equatable {
    var schemaVersion: String
    var status: String
    var actionKind: String?
    var targetID: String?
    var executed: Bool?
    var error: String?
    var voiceLine: String?
    var steerDraft: HUDControlSteerDraft?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case actionKind = "action_kind"
        case targetID = "target_id"
        case executed
        case error
        case voiceLine = "voice_line"
        case steerDraft = "steer_draft"
    }
}

struct HUDControlSteerDraft: Codable, Equatable {
    var schemaVersion: String
    var generatedAt: String?
    var targetID: String
    var message: String
    var requiresConfirmation: Bool
    var sendStatus: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case targetID = "target_id"
        case message
        case requiresConfirmation = "requires_confirmation"
        case sendStatus = "send_status"
    }
}

struct HUDControlInputEventEnvelope: Codable, Equatable {
    var schemaVersion: String
    var event: HUDControlEvent

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event
    }
}
