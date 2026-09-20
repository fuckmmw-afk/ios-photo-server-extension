import SwiftUI

@main
struct PhotoServerApp: App {
    var body: some Scene { WindowGroup { ConnectionView() } }
}

struct ConnectionView: View {
    @State private var address = Settings.address
    @State private var message = ""
    @State private var checking = false
    var body: some View {
        NavigationStack {
            Form {
                Section("From Apple Photos") {
                    Text("Open a photo → Edit → ⋯ → PhotoServer. Processing begins automatically. Review the result and tap Done, then finish editing in Photos.")
                    Text("The original stays available through Revert to Original. Photos are sent to your Gemini Web server.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Server connection") {
                    TextField("https://photo.fuckmmw.space", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Save and check connection") {
                        checking = true
                        Task {
                            defer { checking = false }
                            do {
                                try Settings.save(address)
                                message = try await GeminiClient(baseURL: Settings.validatedURL(address)).checkConnection()
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(checking)
                    if checking { ProgressView() }
                    if !message.isEmpty { Text(message).font(.footnote) }
                    Text("The phone talks to \(Settings.defaultAddress) over HTTPS. That hostname reaches the Gemini proxy on the server. localhost on the phone is the phone, not the VPS.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !Settings.appGroupAvailable {
                        Text("Feather installs usually have no App Group, so the Photos extension uses \(Settings.defaultAddress) even if you change this field.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("PhotoServer")
        }
    }
}
