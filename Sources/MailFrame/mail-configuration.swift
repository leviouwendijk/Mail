import Foundation
import IO
import Readers

/// Where mail configuration lives by default: every `*.frame` file in
/// `$XDG_CONFIG_HOME/mail`, or `~/.config/mail`, read in name order. Each file
/// starts with `import Mail;`; account names must be unique across files.
public enum MailConfiguration {
    public enum State: Sendable {
        case loaded(MailAccounts)
        /// No `.frame` file in the directory.
        case missing(directory: String)
        case invalid(file: String, message: String)
    }

    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("mail", isDirectory: true)
    }

    /// The `.frame` files in `directory`, in name order.
    public static func files(
        in directory: URL
    ) throws -> [URL] {
        guard FileSystem.default.exists(directory) else {
            return []
        }
        return try DirectoryInspector(directory).entries()
            .filter { $0.url.pathExtension == "frame" && $0.kind != .directory }
            .map(\.url)
    }

    /// The accounts of every file in `directory`, as one configuration.
    public static func state(
        directory: URL = MailConfiguration.directory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> State {
        let files: [URL]
        do {
            files = try Self.files(in: directory)
        } catch {
            return .invalid(file: directory.path, message: String(describing: error))
        }
        guard !files.isEmpty else {
            return .missing(directory: directory.path)
        }

        var parts: [MailAccounts] = []
        for file in files {
            do {
                let source = try TextFileReader(file).read().text
                parts.append(try MailAccounts(source: source, filePath: file.path, environment: environment))
            } catch {
                return .invalid(file: file.path, message: describe(error))
            }
        }
        do {
            return .loaded(try MailAccounts.merging(parts))
        } catch {
            return .invalid(file: directory.path, message: describe(error))
        }
    }

    static func describe(
        _ error: any Error
    ) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// The default configuration, reloaded only when a file in the directory
/// is added, removed or modified, so a long-running host sees edits.
public final class MailConfigurationStore: @unchecked Sendable {
    public static let standard = MailConfigurationStore()

    public let directory: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var signature: [String: Date?]?
    private var cached: MailConfiguration.State?

    public init(
        directory: URL = MailConfiguration.directory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.directory = directory
        self.environment = environment
    }

    public func state() -> MailConfiguration.State {
        let current = currentSignature()
        lock.lock()
        defer { lock.unlock() }
        if let cached, signature == current {
            return cached
        }
        let state = MailConfiguration.state(directory: directory, environment: environment)
        cached = state
        signature = current
        return state
    }

    private func currentSignature() -> [String: Date?] {
        let files = (try? MailConfiguration.files(in: directory)) ?? []
        return Dictionary(uniqueKeysWithValues: files.map { file in
            (file.path, (try? FileInspector(file).inspect())?.modifiedAt)
        })
    }
}
