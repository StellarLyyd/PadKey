import Foundation

final class PolishService {
    private let store: PadKeyStore
    private let session: URLSession

    init(store: PadKeyStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    func polish(_ text: String, transform: TransformEntry? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        polishDetailed(text, transform: transform, context: .unknown) { result in
            completion(result.map(\.text))
        }
    }

    func polishDetailed(
        _ text: String,
        transform: TransformEntry? = nil,
        context: PolishContext = .unknown,
        completion: @escaping (Result<PolishResult, Error>) -> Void
    ) {
        let startedAt = Date()
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            completion(.failure(PolishError.emptyInput))
            return
        }

        let apiKey = store.geminiAPIKey
        guard !apiKey.isEmpty else {
            completion(.success(PolishResult(
                text: Self.localPolish(input),
                usedAI: false,
                provider: "Local cleanup",
                duration: Date().timeIntervalSince(startedAt),
                fallbackReason: "Gemini API key is not configured."
            )))
            return
        }

        callGemini(apiKey: apiKey, input: input, transform: transform, context: context, startedAt: startedAt, completion: completion)
    }

    private func callGemini(
        apiKey: String,
        input: String,
        transform: TransformEntry?,
        context: PolishContext,
        startedAt: Date,
        completion: @escaping (Result<PolishResult, Error>) -> Void
    ) {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components?.url else {
            completion(.failure(PolishError.invalidEndpoint))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemInstruction = "You polish dictated text. Preserve the user's preferred names, spellings, cadence, and meaning. Respect the target app context. Return only the rewritten text, with no markdown fence, no commentary, and no surrounding quotes."
        let instruction = transform?.prompt ?? "Improve clarity, grammar, punctuation, and concision while preserving meaning and the writer's voice."
        let voiceContext = store.voiceSyncPrompt
        let prompt = PolishPromptBuilder.prompt(
            input: input,
            instruction: instruction,
            voiceContext: voiceContext,
            context: context
        )

        let payload = GeminiRequest(
            systemInstruction: GeminiSystemInstruction(parts: [GeminiPart(text: systemInstruction)]),
            contents: [GeminiContent(parts: [GeminiPart(text: prompt)])],
            generationConfig: GeminiGenerationConfig(temperature: 0.35, maxOutputTokens: 2048)
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                self?.store.addGeminiFailure(error.localizedDescription)
                completion(.success(Self.localFallback(input, startedAt: startedAt, reason: error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self?.store.addGeminiFailure(PolishError.invalidResponse.localizedDescription)
                completion(.success(Self.localFallback(input, startedAt: startedAt, reason: PolishError.invalidResponse.localizedDescription)))
                return
            }

            guard (200..<300).contains(httpResponse.statusCode), let data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                self?.store.addGeminiFailure("HTTP \(httpResponse.statusCode): \(body)")
                completion(.success(Self.localFallback(input, startedAt: startedAt, reason: "HTTP \(httpResponse.statusCode)")))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
                let text = decoded.candidates
                    .flatMap { $0.content.parts }
                    .compactMap(\.text)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else {
                    self?.store.addGeminiFailure(PolishError.emptyResponse.localizedDescription)
                    completion(.success(Self.localFallback(input, startedAt: startedAt, reason: PolishError.emptyResponse.localizedDescription)))
                    return
                }

                self?.store.addGeminiUsage(promptCharacters: prompt.count, responseCharacters: text.count)
                completion(.success(PolishResult(
                    text: text,
                    usedAI: true,
                    provider: "Gemini 2.0 Flash",
                    duration: Date().timeIntervalSince(startedAt),
                    fallbackReason: nil
                )))
            } catch {
                self?.store.addGeminiFailure(error.localizedDescription)
                completion(.success(Self.localFallback(input, startedAt: startedAt, reason: error.localizedDescription)))
            }
        }.resume()
    }

    private static func localFallback(_ input: String, startedAt: Date, reason: String) -> PolishResult {
        PolishResult(
            text: localPolish(input),
            usedAI: false,
            provider: "Local cleanup",
            duration: Date().timeIntervalSince(startedAt),
            fallbackReason: reason
        )
    }

    private static func localPolish(_ input: String) -> String {
        var text = TextCleanup.clean(input)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if let first = text.first, first.isLowercase {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        if let last = text.last, !".?!".contains(last) {
            text.append(".")
        }
        return text
    }
}

enum PolishError: LocalizedError {
    case emptyInput
    case invalidEndpoint
    case invalidResponse
    case emptyResponse
    case apiFailure(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "There is no text to polish yet."
        case .invalidEndpoint:
            return "The Gemini endpoint could not be created."
        case .invalidResponse:
            return "Gemini returned an invalid response."
        case .emptyResponse:
            return "Gemini returned an empty polish result."
        case .apiFailure(let body):
            return "Gemini polish failed: \(body)"
        }
    }
}

private struct GeminiRequest: Encodable {
    let systemInstruction: GeminiSystemInstruction
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig

    enum CodingKeys: String, CodingKey {
        case systemInstruction = "system_instruction"
        case contents
        case generationConfig
    }
}

private struct GeminiSystemInstruction: Encodable {
    let parts: [GeminiPart]
}

private struct GeminiContent: Codable {
    var parts: [GeminiPart]
}

private struct GeminiPart: Codable {
    var text: String?
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double
    let maxOutputTokens: Int
}

private struct GeminiResponse: Decodable {
    let candidates: [GeminiCandidate]
}

private struct GeminiCandidate: Decodable {
    let content: GeminiContent
}
