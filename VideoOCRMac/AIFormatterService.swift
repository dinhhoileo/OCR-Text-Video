import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case gemini = "Gemini"
    case openai = "OpenAI"
    case claude = "Claude"
    
    var id: String { self.rawValue }
    
    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-2.5-flash"
        case .openai: return "gpt-4o-mini"
        case .claude: return "claude-3-5-sonnet-20241022"
        }
    }
}

struct AIConfig {
    static let providerKey = "ai_provider"
    static let apiKeyKey = "ai_api_key"
    static let modelKey = "ai_model"
    
    static var savedProvider: AIProvider {
        guard let value = UserDefaults.standard.string(forKey: providerKey),
              let provider = AIProvider(rawValue: value) else {
            return .gemini
        }
        return provider
    }
    
    static var savedAPIKey: String {
        UserDefaults.standard.string(forKey: apiKeyKey) ?? ""
    }
    
    static var savedModel: String {
        let model = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return model.isEmpty ? savedProvider.defaultModel : model
    }
    
    static func save(provider: AIProvider, apiKey: String, model: String) {
        UserDefaults.standard.set(provider.rawValue, forKey: providerKey)
        UserDefaults.standard.set(apiKey, forKey: apiKeyKey)
        UserDefaults.standard.set(model, forKey: modelKey)
    }
}

final class AIFormatterService {
    
    func formatText(_ rawText: String, onModelAttempt: ((String) -> Void)? = nil) async throws -> String {
        let provider = AIConfig.savedProvider
        let apiKey = AIConfig.savedAPIKey
        let model = AIConfig.savedModel
        
        guard !apiKey.isEmpty else {
            throw NSError(domain: "AIFormatter", code: 401, userInfo: [NSLocalizedDescriptionKey: "API Key is missing. Please add it in Settings."])
        }
        
        let systemPrompt = """
You are an expert document layout formatter. Given the raw OCR text extracted from an image or video screenshot, your job is to reconstruct the original document layout as closely as possible.
Rules:
1. Strip out unnecessary UI noise (menu bars, titles, time/status bars, dock items, system buttons, window controls).
2. Clean up errors or broken characters, but preserve all meaningful text.
3. Organize the text with proper Markdown structure (headings #/##, paragraphs, lists, tables).
4. Maintain the original language (Vietnamese, English, or mixed).
5. Output ONLY clean Markdown content. Do not wrap it in markdown code blocks like ```markdown.
"""

        switch provider {
        case .gemini:
            return try await callGemini(rawText: rawText, systemPrompt: systemPrompt, apiKey: apiKey, model: model, onModelAttempt: onModelAttempt)
        case .openai:
            onModelAttempt?(model)
            return try await callOpenAI(rawText: rawText, systemPrompt: systemPrompt, apiKey: apiKey, model: model)
        case .claude:
            onModelAttempt?(model)
            return try await callClaude(rawText: rawText, systemPrompt: systemPrompt, apiKey: apiKey, model: model)
        }
    }
    
    // MARK: - API Callers
    
    private func callGemini(
        rawText: String,
        systemPrompt: String,
        apiKey: String,
        model: String,
        onModelAttempt: ((String) -> Void)?
    ) async throws -> String {
        var modelsToTry = [model]
        // Ordered by free-tier headroom (TPM/RPD) on the Gemini API as of today.
        // Pro-tier models report 0 free-tier quota, so they're kept last as a paid-plan fallback.
        let standardFallbacks = [
            "gemini-2.5-flash",
            "gemini-3.1-flash-lite",
            "gemini-3-flash",
            "gemini-3.5-flash",
            "gemini-2.5-flash-lite",
            "gemini-2.5-pro",
            "gemini-3.1-pro"
        ]

        for fallback in standardFallbacks where fallback != model {
            modelsToTry.append(fallback)
        }

        var lastError: Error?
        for currentModel in modelsToTry {
            onModelAttempt?(currentModel)
            do {
                return try await executeGeminiRequest(rawText: rawText, systemPrompt: systemPrompt, apiKey: apiKey, model: currentModel)
            } catch {
                lastError = error
                let nsError = error as NSError
                let errorStr = error.localizedDescription.lowercased()

                // Keep trying the next model on rate limit/quota errors, when this
                // particular model isn't available to the API key (404/not found),
                // or when the request simply timed out (large OCR payloads can be slow).
                let isRetryable = nsError.code == 429 || nsError.code == 404
                    || nsError.code == NSURLErrorTimedOut
                    || errorStr.contains("429") || errorStr.contains("quota") || errorStr.contains("limit")
                    || errorStr.contains("404") || errorStr.contains("not found")
                    || errorStr.contains("timed out")
                if isRetryable {
                    print("Gemini model \(currentModel) unavailable (\(nsError.code)). Trying fallback...")
                    continue
                } else {
                    // Different error (e.g. invalid key 401/400), throw immediately
                    throw error
                }
            }
        }

        throw lastError ?? NSError(domain: "GeminiAPI", code: 429, userInfo: [NSLocalizedDescriptionKey: "All fallback Gemini models failed due to rate limits or quota."])
    }
    
    private func executeGeminiRequest(rawText: String, systemPrompt: String, apiKey: String, model: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        let fullPrompt = "\(systemPrompt)\n\nRaw OCR text to format:\n\(rawText)"
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": fullPrompt]
                    ]
                ]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600 // effectively no timeout: wait until it finishes or the server cuts it off
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "GeminiAPI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw NSError(domain: "GeminiAPI", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid API response structure."])
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func callOpenAI(rawText: String, systemPrompt: String, apiKey: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { throw URLError(.badURL) }
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": rawText]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3600 // effectively no timeout: wait until it finishes or the server cuts it off
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "OpenAIAPI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(domain: "OpenAIAPI", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid API response structure."])
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func callClaude(rawText: String, systemPrompt: String, apiKey: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw URLError(.badURL) }
        
        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": rawText]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 3600 // effectively no timeout: wait until it finishes or the server cuts it off
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "ClaudeAPI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw NSError(domain: "ClaudeAPI", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid API response structure."])
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
