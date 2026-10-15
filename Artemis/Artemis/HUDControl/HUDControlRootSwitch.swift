import Foundation
import SwiftUI

struct HUDControlRootSwitch<DefaultContent: View>: View {
    private let defaultContent: DefaultContent

    init(@ViewBuilder defaultContent: () -> DefaultContent) {
        self.defaultContent = defaultContent()
    }

    var body: some View {
        if HUDControlRuntime.isEnabled {
            HUDControlView(baseURL: HUDControlRuntime.baseURL)
        } else {
            defaultContent
        }
    }
}

enum HUDControlRuntime {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--run-hud-control-mode")
    }

    static var baseURL: URL {
        if let value = ProcessInfo.processInfo.environment["HUD_CONTROL_BASE_URL"],
           let url = URL(string: value) {
            return url
        }
        if let telemetryURL = Bundle.main.object(forInfoDictionaryKey: "ArtemisTelemetryEndpoints") as? [String],
           let firstEndpoint = telemetryURL.compactMap(URL.init(string:)).first,
           let host = firstEndpoint.host {
            var components = URLComponents()
            components.scheme = firstEndpoint.scheme ?? "http"
            components.host = host
            components.port = 8788
            if let url = components.url {
                return url
            }
        }
        return URL(string: "http://127.0.0.1:8788")!
    }
}
