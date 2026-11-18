import Foundation

/// A buffered connection to a line-oriented mail server.
public protocol MailTransport: Sendable {
    func write(_ data: Data) async throws
    /// The next line from the server, without its CRLF.
    func readLine() async throws -> String
    /// Exactly `count` bytes, as for an IMAP `{count}` literal.
    func read(count: Int) async throws -> Data
    /// Upgrades the open connection to TLS after a `STARTTLS` exchange.
    func startTLS() async throws
    func close() async
}

public extension MailTransport {
    func writeLine(
        _ line: String
    ) async throws {
        try await write(Data((line + "\r\n").utf8))
    }
}

/// A TCP connection through `URLSessionStreamTask`, which, unlike
/// Network.framework, can upgrade an open connection to TLS (`STARTTLS`).
public actor StreamMailTransport: MailTransport {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private let timeout: TimeInterval
    private var buffer = Data()
    private var secured: Bool

    public static func connect(
        host: String,
        port: UInt16,
        security: MailSecurity,
        timeout: Duration
    ) async throws -> StreamMailTransport {
        guard port > 0 else {
            throw MailConnectionError.invalidPort(port)
        }
        let seconds = TimeInterval(timeout.components.seconds)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds
        let session = URLSession(configuration: configuration)
        let task = session.streamTask(withHostName: host, port: Int(port))
        task.resume()

        let transport = StreamMailTransport(
            session: session,
            task: task,
            timeout: seconds,
            secured: security == .implicitTLS
        )
        if security == .implicitTLS {
            task.startSecureConnection()
        }
        return transport
    }

    private init(
        session: URLSession,
        task: URLSessionStreamTask,
        timeout: TimeInterval,
        secured: Bool
    ) {
        self.session = session
        self.task = task
        self.timeout = timeout
        self.secured = secured
    }

    public func write(
        _ data: Data
    ) async throws {
        do {
            try await task.write(data, timeout: timeout)
        } catch {
            throw Self.connectionError(error)
        }
    }

    public func readLine() async throws -> String {
        let crlf = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: crlf) {
                let line = buffer[buffer.startIndex..<range.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            buffer.append(try await receive())
        }
    }

    public func read(
        count: Int
    ) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await receive())
        }
        let bytes = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return bytes
    }

    public func startTLS() async throws {
        guard !secured else {
            return
        }
        // Bytes already buffered were sent before the handshake and are not
        // protected by it; accepting them would allow command injection.
        guard buffer.isEmpty else {
            throw MailConnectionError.unexpectedDataBeforeTLS
        }
        task.startSecureConnection()
        secured = true
    }

    public func close() {
        task.closeWrite()
        task.cancel()
        session.invalidateAndCancel()
    }

    private func receive() async throws -> Data {
        let result: (Data?, Bool)
        do {
            result = try await task.readData(ofMinLength: 1, maxLength: 65_536, timeout: timeout)
        } catch {
            throw Self.connectionError(error)
        }
        if let data = result.0, !data.isEmpty {
            return data
        }
        if result.1 {
            throw MailConnectionError.connectionClosed
        }
        return Data()
    }

    private static func connectionError(
        _ error: any Error
    ) -> MailConnectionError {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timedOut
        }
        return .connectionFailed(error.localizedDescription)
    }
}
