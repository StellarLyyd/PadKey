import AppKit
import Foundation
import Network

final class LocalCommandServer {
    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct HealthResponse: Codable {
        let ok: Bool
        let service: String
        let version: Int
        let accessibilityReady: Bool
    }

    private struct AccessibilityResponse: Codable {
        let frontmostApp: FrontmostAppInfo
        let nodes: [AccessibilityNode]
    }

    // PadKey owns a separate loopback endpoint so it can coexist with the
    // standalone OwoFlow agent on 8788.
    static let defaultPort: UInt16 = 8789

    private let coordinator: MacCommandCoordinator
    private let accessibility: AccessibilityTreeService
    private let queue = DispatchQueue(label: "com.stellarlyyd.padkey.command-server", qos: .userInitiated)
    private var listener: NWListener?
    private var recentRequestTimes: [Date] = []

    init(
        coordinator: MacCommandCoordinator = .shared,
        accessibility: AccessibilityTreeService = .shared
    ) {
        self.coordinator = coordinator
        self.accessibility = accessibility
    }

    func start(port: UInt16 = LocalCommandServer.defaultPort) throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw UIAutomationError.unsupported("The local command port is invalid.")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state {
                // The app UI reports reachability; no request content is logged here.
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }
            if nextBuffer.count > 65_536 {
                self.sendError(connection, status: 413, code: "BODY_TOO_LARGE", message: "Request body is too large.")
                return
            }
            if let request = self.parseRequest(nextBuffer) {
                self.route(request, connection: connection)
                return
            }
            if error != nil || isComplete {
                self.sendError(connection, status: 400, code: "MALFORMED_REQUEST", message: "The local command request was malformed.")
                return
            }
            self.receive(connection, buffer: nextBuffer)
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let pieces = requestLine.split(separator: " ")
        guard pieces.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return HTTPRequest(
            method: String(pieces[0]).uppercased(),
            path: String(pieces[1]).components(separatedBy: "?").first ?? String(pieces[1]),
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func route(_ request: HTTPRequest, connection: NWConnection) {
        if request.method == "GET", request.path == "/" || request.path.hasPrefix("/studio") {
            serveStudio(path: request.path, connection: connection, origin: request.headers["origin"])
            return
        }

        guard allowRequest() else {
            sendError(connection, status: 429, code: "RATE_LIMITED", message: "Too many local command requests. Try again shortly.", retryAfter: 5, origin: request.headers["origin"])
            return
        }
        guard originAllowed(request.headers["origin"]) else {
            sendError(connection, status: 403, code: "ORIGIN_BLOCKED", message: "This website is not allowed to control PadKey.")
            return
        }

        if request.method == "OPTIONS" {
            send(connection, status: 204, body: Data(), contentType: "text/plain", origin: request.headers["origin"])
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            sendJSON(connection, status: 200, value: HealthResponse(
                ok: true,
                service: "PadKey Mac Action Agent",
                version: 1,
                accessibilityReady: PermissionHelper.isAccessibilityTrusted
            ), origin: request.headers["origin"])

        case ("GET", "/permissions"):
            sendJSON(connection, status: 200, value: coordinator.permissions(), origin: request.headers["origin"])

        case ("GET", "/accessibility-tree"):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                do {
                    let preferred = AppDelegate.shared?.preferredMacCommandApplication()
                    let app = try self.accessibility.frontmostApp(preferred: preferred)
                    let nodes = try self.accessibility.getAccessibilityTree(for: preferred)
                    self.sendJSON(connection, status: 200, value: AccessibilityResponse(frontmostApp: app, nodes: nodes), origin: request.headers["origin"])
                } catch AccessibilityTreeError.permissionRequired {
                    self.sendError(connection, status: 403, code: "ACCESSIBILITY_REQUIRED", message: "Enable Accessibility for the packaged PadKey app.", origin: request.headers["origin"])
                } catch {
                    self.sendError(connection, status: 422, code: "INSPECTION_FAILED", message: error.localizedDescription, origin: request.headers["origin"])
                }
            }

        case ("POST", "/command"):
            guard let command = try? JSONDecoder().decode(MacCommandRequest.self, from: request.body) else {
                sendError(connection, status: 400, code: "INVALID_COMMAND", message: "A transcript is required.", origin: request.headers["origin"])
                return
            }
            let transcript = command.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty, transcript.count <= 4_000 else {
                sendError(connection, status: 422, code: "INVALID_TRANSCRIPT", message: "Provide a transcript between 1 and 4,000 characters.", origin: request.headers["origin"])
                return
            }
            guard command.mode == nil || command.mode == "mac_control" else {
                sendError(connection, status: 422, code: "INVALID_MODE", message: "Only mac_control mode is supported.", origin: request.headers["origin"])
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let preferred = AppDelegate.shared?.preferredMacCommandApplication()
                self.coordinator.execute(request: command, preferredApplication: preferred) { response in
                    self.sendJSON(connection, status: response.ok ? 200 : response.permissionRequired == nil ? 422 : 403, value: response, origin: request.headers["origin"])
                }
            }

        case ("POST", "/confirm"):
            guard let confirmation = try? JSONDecoder().decode(CommandConfirmationRequest.self, from: request.body),
                  !confirmation.confirmationId.isEmpty
            else {
                sendError(connection, status: 400, code: "INVALID_CONFIRMATION", message: "A confirmationId is required.", origin: request.headers["origin"])
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator.confirm(id: confirmation.confirmationId) { response in
                    self.sendJSON(connection, status: response.ok ? 200 : 409, value: response, origin: request.headers["origin"])
                }
            }

        default:
            sendError(connection, status: 404, code: "NOT_FOUND", message: "The requested local agent endpoint does not exist.", origin: request.headers["origin"])
        }
    }

    private func serveStudio(path: String, connection: NWConnection, origin: String?) {
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.contains("..") else {
            sendError(connection, status: 403, code: "INVALID_PATH", message: "Invalid Studio asset path.", origin: origin)
            return
        }
        let relativePath: String
        if decoded == "/" || decoded == "/studio" || decoded == "/studio/" {
            relativePath = "index.html"
        } else {
            relativePath = String(decoded.dropFirst("/studio/".count))
        }

        guard let root = studioResourceRoot() else {
            sendError(connection, status: 503, code: "STUDIO_NOT_INSTALLED", message: "PadKey Studio resources are missing from this app build.", origin: origin)
            return
        }
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            sendError(connection, status: 404, code: "ASSET_NOT_FOUND", message: "The requested Studio asset was not found.", origin: origin)
            return
        }
        send(connection, status: 200, body: data, contentType: contentType(for: fileURL.pathExtension), origin: origin)
    }

    private func studioResourceRoot() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Studio"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../../padkey-studio/dist")
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: development.appendingPathComponent("index.html").path) ? development : nil
    }

    private func contentType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "wasm": return "application/wasm"
        case "onnx": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }

    private func allowRequest() -> Bool {
        let now = Date()
        recentRequestTimes = recentRequestTimes.filter { now.timeIntervalSince($0) < 60 }
        guard recentRequestTimes.count < 60 else { return false }
        recentRequestTimes.append(now)
        return true
    }

    private func originAllowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    private func sendJSON<T: Encodable>(
        _ connection: NWConnection,
        status: Int,
        value: T,
        origin: String?
    ) {
        guard let data = try? JSONEncoder().encode(value) else {
            sendError(connection, status: 500, code: "ENCODING_FAILED", message: "The local agent could not prepare its response.", origin: origin)
            return
        }
        send(connection, status: status, body: data, contentType: "application/json; charset=utf-8", origin: origin)
    }

    private func sendError(
        _ connection: NWConnection,
        status: Int,
        code: String,
        message: String,
        retryAfter: Int? = nil,
        origin: String? = nil
    ) {
        let envelope = APIErrorEnvelope(error: .init(code: code, message: message, traceId: UUID().uuidString))
        let data = (try? JSONEncoder().encode(envelope)) ?? Data("{\"error\":{\"code\":\"UNKNOWN\",\"message\":\"Local agent error\"}}".utf8)
        send(connection, status: status, body: data, contentType: "application/json; charset=utf-8", origin: origin, retryAfter: retryAfter)
    }

    private func send(
        _ connection: NWConnection,
        status: Int,
        body: Data,
        contentType: String,
        origin: String?,
        retryAfter: Int? = nil
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 422: reason = "Unprocessable Entity"
        case 429: reason = "Too Many Requests"
        case 503: reason = "Service Unavailable"
        default: reason = "Internal Server Error"
        }
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type"
        ]
        if let origin, originAllowed(origin) {
            headers.append("Access-Control-Allow-Origin: \(origin)")
            headers.append("Vary: Origin")
        }
        if let retryAfter { headers.append("Retry-After: \(retryAfter)") }
        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
