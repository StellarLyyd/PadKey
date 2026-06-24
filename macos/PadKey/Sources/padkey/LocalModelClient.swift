import Foundation

enum LocalModelError: LocalizedError {
    case offline
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "Local model is offline. I can still run basic commands."
        case .invalidResponse:
            return "The local model returned an invalid action plan."
        case .server(let message):
            return message
        }
    }
}

final class LocalModelClient {
    private struct OllamaMessage: Codable {
        let role: String
        let content: String
    }

    private struct OllamaRequest: Codable {
        let model: String
        let messages: [OllamaMessage]
        let stream: Bool
        let format: String?
        let options: [String: Double]
    }

    private struct OllamaResponse: Codable {
        let message: OllamaMessage
    }

    private let endpoint: URL
    private let model: String
    private let session: URLSession

    init(
        endpoint: URL? = nil,
        model: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.endpoint = endpoint
            ?? environment["PADKEY_OLLAMA_ENDPOINT"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:11434/api/chat")!
        self.model = model
            ?? environment["PADKEY_OLLAMA_MODEL"]
            ?? "qwen2.5:7b"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 14
        configuration.timeoutIntervalForResource = 18
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func chat(
        system: String,
        user: String,
        requireJSON: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OllamaRequest(
            model: model,
            messages: [
                OllamaMessage(role: "system", content: system),
                OllamaMessage(role: "user", content: user)
            ],
            stream: false,
            format: requireJSON ? "json" : nil,
            options: ["temperature": 0.0]
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error = error as? URLError,
               [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut].contains(error.code)
            {
                completion(.failure(LocalModelError.offline))
                return
            }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(LocalModelError.invalidResponse))
                return
            }
            guard (200..<300).contains(http.statusCode), let data else {
                completion(.failure(LocalModelError.server("Local model returned HTTP \(http.statusCode).")))
                return
            }
            guard let decoded = try? JSONDecoder().decode(OllamaResponse.self, from: data) else {
                completion(.failure(LocalModelError.invalidResponse))
                return
            }
            completion(.success(decoded.message.content))
        }.resume()
    }
}
