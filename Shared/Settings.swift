import Foundation

enum Settings {
    static let defaultAddress = "https://photo.fuckmmw.space"
    static let model = "gemini-3.6-flash"
    // Replace this instruction in a later iteration; no prompt editor in the extension.
    static let prompt = "Process the attached photograph while preserving its subjects, faces and composition. Return the resulting photograph as an image, not a text description."
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "PhotoServerAppGroup") as? String ?? "group.com.example.PhotoServer" }
    static var appGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }
    // Sideload certificates (Feather) usually have no App Group. Fall back to this process's defaults
    // and the compiled default URL so the Photos extension can still run.
    static var defaults: UserDefaults {
        if appGroupAvailable, let suite = UserDefaults(suiteName: groupID) { return suite }
        return .standard
    }
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
        defaults.set(url.absoluteString, forKey: "serverAddress")
        defaults.synchronize()
    }
}

enum PhotoError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
