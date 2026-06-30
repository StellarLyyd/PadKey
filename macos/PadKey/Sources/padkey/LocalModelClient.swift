import Foundation

enum LocalModelError: LocalizedError {
    case offline
    case timedOut
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "Local model is offline. I can still run basic commands."
        case .timedOut:
            return "Local model took too long. I can still inspect and run direct Mac controls."
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
    private let modelCandidates: [String]
    private let session: URLSession
    private let hardTimeoutSeconds: TimeInterval

    init(
        endpoint: URL? = nil,
        model: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.endpoint = endpoint
            ?? environment["PADKEY_OLLAMA_ENDPOINT"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:11434/api/chat")!
        let primaryModel = model
            ?? environment["PADKEY_OLLAMA_MODEL"]
            ?? "gemma4:12b-mlx"
        let fallbackModels = environment["PADKEY_OLLAMA_FALLBACK_MODELS"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            ?? ["gemma4:12b-mlx", "qwen3:4b", "qwen2.5:7b", "qwen2.5-coder:7b"]
        self.modelCandidates = Self.uniqueModels([primaryModel] + fallbackModels)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 14
        configuration.timeoutIntervalForResource = 18
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        hardTimeoutSeconds = environment["PADKEY_LOCAL_MODEL_TIMEOUT_SECONDS"]
            .flatMap(Double.init)
            .map { max(4, min($0, 30)) }
            ?? 5
    }

    func chat(
        system: String,
        user: String,
        requireJSON: Bool,
        temperature: Double = 0.0,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        sendChat(
            modelIndex: 0,
            system: system,
            user: user,
            requireJSON: requireJSON,
            temperature: temperature,
            completion: completion
        )
    }

    private func sendChat(
        modelIndex: Int,
        system: String,
        user: String,
        requireJSON: Bool,
        temperature: Double,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let selectedModel = modelCandidates[min(modelIndex, modelCandidates.count - 1)]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OllamaRequest(
            model: selectedModel,
            messages: [
                OllamaMessage(role: "system", content: system),
                OllamaMessage(role: "user", content: user)
            ],
            stream: false,
            format: requireJSON ? "json" : nil,
            options: ["temperature": temperature]
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(error))
            return
        }

        let lock = NSLock()
        var didComplete = false
        var timeoutWork: DispatchWorkItem?
        var task: URLSessionDataTask?

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            if didComplete {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()
            timeoutWork?.cancel()
            completion(result)
        }

        let workItem = DispatchWorkItem {
            task?.cancel()
            finish(.failure(LocalModelError.timedOut))
        }
        timeoutWork = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + hardTimeoutSeconds, execute: workItem)

        task = session.dataTask(with: request) { data, response, error in
            if let error = error as? URLError,
               [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut].contains(error.code)
            {
                finish(.failure(LocalModelError.offline))
                return
            }
            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    finish(.failure(LocalModelError.timedOut))
                } else {
                    finish(.failure(error))
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(LocalModelError.invalidResponse))
                return
            }
            guard (200..<300).contains(http.statusCode), let data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if self.shouldTryFallback(statusCode: http.statusCode, body: body),
                   modelIndex + 1 < self.modelCandidates.count
                {
                    self.sendChat(
                        modelIndex: modelIndex + 1,
                        system: system,
                        user: user,
                        requireJSON: requireJSON,
                        temperature: temperature,
                        completion: finish
                    )
                    return
                }
                let message = body.isEmpty ? "Local model returned HTTP \(http.statusCode)." : body
                finish(.failure(LocalModelError.server(message)))
                return
            }
            guard let decoded = try? JSONDecoder().decode(OllamaResponse.self, from: data) else {
                finish(.failure(LocalModelError.invalidResponse))
                return
            }
            finish(.success(decoded.message.content))
        }
        task?.resume()
    }

    private func shouldTryFallback(statusCode: Int, body: String) -> Bool {
        statusCode == 404
            || body.localizedCaseInsensitiveContains("not found")
            || body.localizedCaseInsensitiveContains("pull model")
    }

    private static func uniqueModels(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        return models.filter { model in
            guard !seen.contains(model) else { return false }
            seen.insert(model)
            return true
        }
    }
}
