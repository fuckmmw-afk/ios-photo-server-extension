import Foundation

enum Settings {
    static let defaultAddress = "http://localhost:4981"
    static let model = "gemini-3.6-flash"
    // Replace this instruction in a later iteration; no prompt editor in the extension.
    static let prompt = "Process the attached photograph while preserving its subjects, faces and composition. Return the resulting photograph as an image, not a text description."
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "PhotoServerAppGroup") as? String ?? "group.com.example.PhotoServer" }
    static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }
    static var address: String { defaults.string(forKey: "serverAddress") ?? defaultAddress }

    static func validatedURL(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw PhotoError.message("Use HTTPS or a local SSH tunnel: http://localhost:4981")
        }
        return url
    }
    static func save(_ address: String) throws {
        let url = try validatedURL(address)
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil else {
            throw PhotoError.message("App Group is unavailable. The installed app and extension must have matching App Group entitlements.")
        }
        defaults.set(url.absoluteString, forKey: "serverAddress")
    }
}

enum PhotoError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
