import SwiftUI

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var provider: AIProvider = AIConfig.savedProvider
    @State private var apiKey: String = AIConfig.savedAPIKey
    @State private var model: String = AIConfig.savedModel
    
    @State private var testStatus: String? = nil
    @State private var testStatusIsError = false
    @State private var isTesting = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI Formatter Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    saveAndDismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            Form {
                Section {
                    Picker("AI Provider", selection: $provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .onChange(of: provider) { oldValue, newValue in
                        model = newValue.defaultModel
                    }
                    
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .help("Get your API key from the respective AI platform dashboard.")
                    
                    TextField("Model Name", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .placeholder(when: model.isEmpty) {
                            Text(provider.defaultModel).foregroundColor(.gray)
                        }
                } header: {
                    Text("API Configuration")
                        .font(.subheadline.bold())
                }
                
                if let status = testStatus {
                    Text(status)
                        .foregroundColor(testStatusIsError ? .red : .green)
                        .font(.callout)
                        .padding(.vertical, 4)
                }
                
                HStack {
                    Button(action: testConnection) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 8)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting || apiKey.isEmpty)
                    
                    Spacer()
                    
                    Button("Reset Default Model") {
                        model = provider.defaultModel
                    }
                }
                .padding(.top, 8)
            }
            .padding()
            .formStyle(.grouped)
            
            Divider()
            
            // Footer
            HStack {
                Link("Get Gemini API Key (Free)", destination: URL(string: "https://aistudio.google.com/")!)
                    .font(.caption)
                    .foregroundColor(.blue)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 480, height: 350)
    }
    
    private func saveAndDismiss() {
        AIConfig.save(provider: provider, apiKey: apiKey, model: model)
        dismiss()
    }
    
    private func testConnection() {
        guard !apiKey.isEmpty else { return }
        isTesting = true
        testStatus = "Testing connection..."
        testStatusIsError = false
        
        Task {
            let tempService = AIFormatterService()
            // Temp save values for this call
            AIConfig.save(provider: provider, apiKey: apiKey, model: model)
            
            do {
                let testText = "Hello world"
                _ = try await tempService.formatText(testText)
                
                await MainActor.run {
                    testStatus = "Success! Connection validated."
                    testStatusIsError = false
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testStatus = "Error: \(error.localizedDescription)"
                    testStatusIsError = true
                    isTesting = false
                }
            }
        }
    }
}

// Helper to show placeholder inside TextField
extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {
            
            ZStack(alignment: alignment) {
                placeholder().opacity(shouldShow ? 1 : 0)
                self
            }
        }
}
