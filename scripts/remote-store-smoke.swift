import AppKit
import Foundation
import SwiftUI

@main
enum RemoteStoreSmoke {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for origin in ["http://localhost:3005", "http://127.0.0.1:3005", "https://conductor.example.test"] {
            let validated = try RemoteAccessStore.origin(origin)
            precondition(validated == origin)
        }
        for invalid in ["http://example.test", "https://user:password@example.test", "https://example.test/path", "https://example.test?token=x", "file:///tmp/test"] {
            do { _ = try RemoteAccessStore.origin(invalid); fatalError("Unsafe origin accepted") } catch {}
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = RemoteConfiguration(backendUrl: "https://conductor.example.test", deviceId: UUID().uuidString.lowercased(), email: "fixture@example.test", workspaces: [RemoteWorkspace(id: UUID().uuidString.lowercased(), label: "Fixture", path: "/tmp/fixture")])
        precondition(config.command["backend_url"] as? String == config.backendUrl)
        precondition(config.command["device_id"] as? String == config.deviceId)
        let store = EngineStore(options: LaunchOptions())
        let bytes = try JSONSerialization.data(withJSONObject: ["type": "remote_state", "remote": ["state": "online", "config":config.command]])
        let event = try decoder.decode(EngineEvent.self, from: bytes)
        store.apply(event, rendered: [:], chat: [:])
        precondition(store.remote.state == "online" && store.remote.config == config)
        precondition(store.runs.isEmpty && store.prompt.isEmpty, "Remote status must not alter a chat")
        let disabled = try decoder.decode(EngineEvent.self, from: Data("{\"type\":\"remote_state\",\"remote\":{\"state\":\"disabled\",\"config\":null}}".utf8))
        store.apply(disabled, rendered: [:], chat: [:])
        precondition(!store.remote.enabled && store.remote.state == "disabled")
        print("PASS: native remote origins, configuration encoding, bridge status and disconnect")
    }
}
