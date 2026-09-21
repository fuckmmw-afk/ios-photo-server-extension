import SwiftUI

@main
struct PhotoServerApp: App {
    var body: some Scene { WindowGroup { ConnectionView() } }
}

struct ConnectionView: View {
    @State private var address = Settings.address
    @State private var apiKey = Settings.apiKey
    @State private var message = ""
    @State private var checking = false
    var body: some View {
        NavigationStack {
            Form {
                Section("From Apple Photos") {
                    Text("Open a photo → Edit → ⋯ → PhotoServer. Processing begins automatically. Review the result and tap Done, then finish editing in Photos.")
                    Text("The original stays available through Revert to Original. Photos are sent to the server you configure below.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Server connection") {
                    TextField("https://photo.example.com", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("PhotoServer API key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                    Button("Save and check connection") {
                        checking = true
                        Task {
                            defer { checking = false }
                            do {
                                let configuration = try Settings.configuration(address: address, apiKey: apiKey)
                                let connected = try await GeminiClient(configuration: configuration).checkConnection()
                                guard Settings.appGroupAvailable else {
                                    message = "\(connected), but this install cannot save credentials for the Photos extension. Re-sign both targets with an App Group profile."
                                    return
                                }
                                try Settings.save(configuration)
                                message = connected
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(checking)
                    if checking { ProgressView() }
                    if !message.isEmpty { Text(message).font(.footnote) }
                    Text("Use HTTPS for a remote server. HTTP is allowed only for localhost or an SSH tunnel. The API key is shared only by this app and its Photos extension through the App Group.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !Settings.appGroupAvailable {
                        Text("You can test the connection, but this build has no usable App Group. Re-sign both the app and extension with a profile that authorizes \(Settings.groupID) before Photos can receive its server credentials.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("PhotoServer")
        }
    }
}
