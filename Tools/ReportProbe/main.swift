import Foundation

// 本地验收工具：起一个 HTTP 服务，收集客户端真实发出的请求，
// 用与后端契约一致的方式校验（scope / header / 幂等键 / JSON 结构）。
//
// 用法：swift run ReportProbe [端口]
// 然后让 App 把 endpoint 指向 http://127.0.0.1:<端口>/touchpad-gestures/v1/report
// （调试期可通过 ReportScope.endpointOverride 覆盖，正式版为空）。

final class ProbeServer {
    private let port: UInt16
    private var listener: Socket?
    private(set) var received: [(path: String, headers: [String: String], body: Data)] = []

    init(port: UInt16) { self.port = port }

    func start() throws {
        let socket = try Socket(port: port)
        listener = socket
        DispatchQueue.global().async { [weak self] in
            while let client = try? socket.accept() {
                self?.handle(client)
            }
        }
        print("[probe] listening on http://127.0.0.1:\(port)")
        print("[probe] POST /touchpad-gestures/v1/report")
    }

    private func handle(_ client: Socket) {
        defer { client.close() }
        guard let request = try? client.readRequest() else { return }
        let headers = request.headers
        let body = request.body

        // —— 契约校验 ——
        var failures: [String] = []
        if request.path != "/touchpad-gestures/v1/report" {
            failures.append("path 不符: \(request.path)")
        }
        if headers["x-debug-scope"] != "touchpad-gestures" {
            failures.append("X-Debug-Scope 缺失/不符")
        }
        if headers["x-debug-schema"] != "1" {
            failures.append("X-Debug-Schema 缺失/不符")
        }
        if headers["x-client-token"]?.isEmpty ?? true {
            failures.append("X-Client-Token 缺失")
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            failures.append("body 不是 JSON")
            respond(client, status: 400, json: ["ok": false])
            return
        }
        let report = json["report"] as? [String: Any]
        let reportID = report?["id"] as? String
        if let id = reportID, headers["idempotency-key"] != id {
            failures.append("Idempotency-Key 与 report.id 不一致")
        }
        if (json["scope"] as? [String: Any])?["project"] as? String != "touchpad-gestures" {
            failures.append("scope.project 不符")
        }
        for key in ["schema_version", "errors", "environment", "consent"] where json[key] == nil {
            failures.append("缺少字段 \(key)")
        }

        received.append((request.path, headers, body))
        print("[probe] ← \(request.path)  \(body.count) bytes  token=\(headers["x-client-token"] ?? "-")")
        if failures.isEmpty {
            print("[probe] ✓ 契约校验通过  id=\(reportID ?? "?")")
        } else {
            print("[probe] ✗ \(failures.joined(separator: "; "))")
        }

        respond(client, status: failures.isEmpty ? 201 : 400,
                json: ["ok": failures.isEmpty, "id": reportID ?? ""])
    }

    private func respond(_ client: Socket, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "HTTP/1.1 \(status) \(status == 201 ? "Created" : "Bad Request")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        try? client.write(Data(head.utf8) + body)
    }
}

// MARK: - 极简 socket 封装（仅本工具使用）

final class Socket {
    private let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProbeError("socket() 失败") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ProbeError("bind() 失败（端口占用？ 错误码 \(errno)）") }
        guard listen(fd, 8) == 0 else { throw ProbeError("listen() 失败") }
    }

    func accept() throws -> Socket {
        var addr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let client = Darwin.accept(fd, &addr, &len)
        guard client >= 0 else { throw ProbeError("accept() 失败") }
        return Socket(descriptor: client)
    }

    private init(descriptor: Int32) { fd = descriptor }

    struct Request {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    func readRequest() throws -> Request {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        // 读到 header 结束
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ProbeError("连接关闭") }
            buffer.append(contentsOf: chunk[0..<n])
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<range.lowerBound]
                let headerText = String(decoding: headerData, as: UTF8.self)
                let lines = headerText.split(separator: "\r\n")
                guard let requestLine = lines.first else { throw ProbeError("空请求") }
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else { throw ProbeError("请求行异常") }
                let path = String(parts[1])

                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }

                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                var body = Data(buffer[range.upperBound...])
                while body.count < contentLength {
                    let n2 = read(fd, &chunk, chunk.count)
                    guard n2 > 0 else { break }
                    body.append(contentsOf: chunk[0..<n2])
                }
                return Request(path: path, headers: headers, body: body)
            }
        }
    }

    func write(_ data: Data) throws {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    func close() { Darwin.close(fd) }
}

struct ProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - main

let port = UInt16(CommandLine.arguments.dropFirst().first ?? "8787") ?? 8787
let server = ProbeServer(port: port)
do {
    try server.start()
} catch {
    print("[probe] 启动失败: \(error.localizedDescription)")
    exit(1)
}
RunLoop.current.run()
