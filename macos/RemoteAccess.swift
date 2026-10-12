import AppKit
import Foundation
import Security
import SwiftUI
import Darwin

struct RemoteWorkspace: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var path: String
}
struct RemoteConfiguration: Codable, Equatable {
    var backendUrl: String
    var deviceId: String
    var email: String
    var workspaces: [RemoteWorkspace]
    var command: [String: Any] {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? JSONSerialization.jsonObject(with: encoder.encode(self))) as? [String: Any] ?? [:]
    }
}
struct RemoteInfo: Decodable {
    var state: String
    var config: RemoteConfiguration?
    var message: String?
}
enum RemoteCredential {
    static let service = "dev.agentconductor.remote.device"
    static func get(_ id: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ token: String, id: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id]
        let data = Data(token.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw RemoteError.message("Could not update the remote credential in Keychain.") }
        var entry = query; entry[kSecValueData] = data; entry[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw RemoteError.message("Could not save the remote credential in Keychain.") }
    }
    static func remove(_ id: String) { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary) }
}
enum RemoteError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}
private final class RemoteSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum RemoteStartup {
    static let label = "dev.agentconductor.host"
    static func change(_ enabled: Bool) async throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plist = directory.appendingPathComponent("\(label).plist")
        if enabled {
            let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/conductor-engine").path
            guard FileManager.default.isExecutableFile(atPath: executable) else { throw RemoteError.message("Install the application bundle before enabling startup.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values: [String: Any] = ["Label": label, "ProgramArguments": [executable, "--daemon", "--supervise"], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10, "ProcessType": "Background"]
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: plist, options: .atomic)
            _ = try await run(["enable", "gui/\(getuid())/\(label)"])
            let status = try await run(["bootstrap", "gui/\(getuid())", plist.path])
            // An already loaded job may be waiting for the current host's lock.
            if status != 0, try await run(["print", "gui/\(getuid())/\(label)"]) != 0 { throw RemoteError.message("Remote sharing is enabled, but startup could not be registered.") }
        } else {
            _ = try await run(["disable", "gui/\(getuid())/\(label)"])
            if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
        }
    }
    private static func run(_ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

@MainActor
final class RemoteAccessStore: ObservableObject {
    @Published var backendURL = UserDefaults.standard.string(forKey: "remote.server") ?? "http://localhost:3005"
    @Published var email = UserDefaults.standard.string(forKey: "remote.email") ?? ""
    @Published var state = "disabled"
    @Published var config: RemoteConfiguration?
    @Published var busy = false
    @Published var message: String?
    @Published var startAtLogin = UserDefaults.standard.bool(forKey: "remote.startup")
    var enabled: Bool { config != nil }
    func receive(_ info: RemoteInfo?) {
        guard let info else { return }
        if state != info.state { state = info.state }
        if config != info.config { config = info.config }
        if message != info.message { message = info.message }
    }
    static func origin(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: text), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else { throw RemoteError.message("Enter a server origin, for example https://conductor.example.com.") }
        guard url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host) else { throw RemoteError.message("Remote servers require HTTPS. Localhost supports HTTP for development.") }
        return text
    }
    private func api(_ session: URLSession, server: String, path: String, method: String, body: [String: Any]?, csrf: String? = nil, token: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: server + "/api/v1" + path) else { throw RemoteError.message("Invalid server URL.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 25
        request.setValue(server, forHTTPHeaderField: "Origin"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let csrf { request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.message("Server did not return an HTTP response.") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else { throw RemoteError.message(object["error"] as? String ?? "Server request failed (\(http.statusCode)).") }
        return object
    }
    private func folders(_ paths: Set<String>) throws -> [RemoteWorkspace] {
        try paths.sorted().map { path in
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw RemoteError.message("A selected workspace no longer exists.") }
            return RemoteWorkspace(id: config?.workspaces.first(where: { $0.path == url.path })?.id ?? UUID().uuidString.lowercased(), label: url.lastPathComponent, path: url.path)
        }
    }
    func connect(password: String, paths: Set<String>, configure: (RemoteConfiguration, String) -> Void) async {
        guard !busy else { return }; busy = true; message = nil; defer { busy = false }
        let session = URLSession(configuration: .ephemeral, delegate: RemoteSessionDelegate(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        do {
            let server = try Self.origin(backendURL); let shared = try folders(paths)
            guard !shared.isEmpty else { throw RemoteError.message("Choose at least one folder to share.") }
            let auth = try await api(session, server: server, path: "/auth/login", method: "POST", body: ["email": email, "password": password])
            guard let csrf = auth["csrf"] as? String else { throw RemoteError.message("Server login response was incomplete.") }
            let enrolled = try await api(session, server: server, path: "/devices", method: "POST", body: ["name": Host.current().localizedName ?? "My Mac", "workspaces": shared.map { ["id": $0.id, "label": $0.label] }], csrf: csrf)
            guard let device = enrolled["device"] as? [String: Any], let id = device["id"] as? String, let token = enrolled["token"] as? String else { throw RemoteError.message("Server pairing response was incomplete.") }
            do { try RemoteCredential.set(token, id: id) } catch { _ = try? await api(session, server: server, path: "/devices/\(id)", method: "DELETE", body: [:], csrf: csrf); throw error }
            let next = RemoteConfiguration(backendUrl: server, deviceId: id, email: email, workspaces: shared)
            configure(next, token)
            UserDefaults.standard.set(server, forKey: "remote.server"); UserDefaults.standard.set(email, forKey: "remote.email")
            _ = try? await api(session, server: server, path: "/auth/logout", method: "POST", body: [:], csrf: csrf)
            try await RemoteStartup.change(startAtLogin); UserDefaults.standard.set(startAtLogin, forKey: "remote.startup")
        } catch { message = error.localizedDescription }
    }
    func saveSharing(paths: Set<String>, configure: (RemoteConfiguration, String) -> Void) async {
        guard !busy, var next = config else { return }; busy = true; message = nil; defer { busy = false }
        do { guard let token = RemoteCredential.get(next.deviceId) else { throw RemoteError.message("The device credential is missing; pair again.") }; next.workspaces = try folders(paths); configure(next, token); try await RemoteStartup.change(startAtLogin); UserDefaults.standard.set(startAtLogin, forKey: "remote.startup") }
        catch { message = error.localizedDescription }
    }
    func disconnect(disable: () -> Void) async {
        guard !busy, let config else { return }; busy = true; defer { busy = false }
        // Local dispatch stops immediately even when the server cannot be reached.
        disable()
        let session = URLSession(configuration: .ephemeral, delegate: RemoteSessionDelegate(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        if let token = RemoteCredential.get(config.deviceId) { do { _ = try await api(session, server: config.backendUrl, path: "/device/revoke", method: "POST", body: [:], token: token) } catch { message = "Sharing stopped locally. The server could not be reached; revoke this computer from the web dashboard when available." } }
        RemoteCredential.remove(config.deviceId); try? await RemoteStartup.change(false)
    }
}

struct RemoteAccessView: View {
    @EnvironmentObject private var store: EngineStore
    var body: some View { RemoteAccessContent(remote: store.remote).environmentObject(store) }
}
private struct RemoteAccessContent: View {
    @EnvironmentObject private var store: EngineStore
    @ObservedObject var remote: RemoteAccessStore
    @State private var password = ""
    @State private var shared = Set<String>()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) { Text("Remote workspace").font(.system(size: 30, weight: .semibold)); Text("Continue your conversations from a browser while this Mac runs your coworkers.").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Image(systemName: "network").foregroundStyle(Theme.accent); Text(remote.enabled ? "\(remote.email.isEmpty ? remote.config?.email ?? "" : remote.email) · \(remote.state.capitalized)" : "Sign in to enable remote access").font(.headline); Spacer() }
                    if !remote.enabled {
                        LabeledContent("Server") { TextField("https://conductor.example.com", text: $remote.backendURL).textFieldStyle(.roundedBorder).frame(maxWidth: 450) }
                        LabeledContent("Email") { TextField("Your account email", text: $remote.email).textFieldStyle(.roundedBorder).frame(maxWidth: 450) }
                        LabeledContent("Password") { SecureField("Account password", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 450) }
                    } else { Text(remote.config?.backendUrl ?? "").foregroundStyle(.secondary).textSelection(.enabled) }
                    Divider(); Text("Folders available remotely").font(.headline)
                    ForEach(store.settings.workspaceFolders, id: \.self) { path in
                        Toggle(isOn: Binding(get: { shared.contains(path) }, set: { if $0 { shared.insert(path) } else { shared.remove(path) } })) { VStack(alignment: .leading, spacing: 3) { Text(store.settings.folderLabel(path)); Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) } }.toggleStyle(.checkbox)
                    }
                    Toggle("Start the background service when I log in to this Mac", isOn: $remote.startAtLogin).toggleStyle(.checkbox)
                    Text("Shared chats, questions and changes are copied to your server for remote history. Provider credentials stay on this Mac. The Mac must be awake and online to run tasks.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let message = remote.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                    HStack {
                        if remote.enabled {
                            Button("Save sharing") { Task { await remote.saveSharing(paths: shared, configure: store.configureRemote) } }.buttonStyle(.borderedProminent)
                            Button("Open web dashboard") { if let url = URL(string: remote.config?.backendUrl ?? "") { NSWorkspace.shared.open(url) } }
                            Spacer(); Button("Disconnect", role: .destructive) { Task { await remote.disconnect(disable: store.disableRemote) } }
                        } else {
                            Button(remote.busy ? "Signing in…" : "Sign in and share selected folders") { Task { let value = password; password = ""; await remote.connect(password: value, paths: shared, configure: store.configureRemote) } }.buttonStyle(.borderedProminent).disabled(password.isEmpty || shared.isEmpty)
                        }
                    }.disabled(remote.busy || !store.connected || store.demo)
                }.padding(24).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                Text("The desktop workspace works locally without an account. Login is required for remote access.").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { shared = Set(remote.config?.workspaces.map(\.path) ?? []) }
        .onChange(of: remote.config) { _, config in if let config { shared = Set(config.workspaces.map(\.path)) } }
    }
}
