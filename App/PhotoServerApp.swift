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
                    TextField("http://localhost:4981", text: $address)
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
                    Text("Keep your SSH tunnel connected while editing. Google cookies stay on the server.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("PhotoServer")
        }
    }
}
