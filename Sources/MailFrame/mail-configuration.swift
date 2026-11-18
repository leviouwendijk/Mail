import Foundation
import Frame
import IO
import Path
import Readers

/// Where mail configuration lives by default: every `*.frame` file in
/// `$XDG_CONFIG_HOME/mail`, or `~/.config/mail`, and its subdirectories,
/// under any names. Each file
/// starts with `import Mail;`; together they form one configuration, so a
/// binding may reference one declared in another file, in any order. Names
/// must be unique across files; accounts keep relative-path order, so the
/// default account is the first in the first file that declares one.
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

    /// The `.frame` files in `directory` and its subdirectories, by relative
    /// path; hidden files are skipped and symbolic links are not followed.
    public static func files(
        in directory: URL
    ) throws -> [URL] {
        guard FileSystem.default.exists(directory) else {
            return []
        }
        return try PathWalker(root: directory, configuration: .init(emitDirectories: false))
            .walk()
            .filter { $0.url.pathExtension == "frame" }
            .sorted { $0.url.path < $1.url.path }
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

        // Every file is parsed on its own; each is then checked with all the
        // others' bindings in scope, so references cross files in any order.
        var parsed: [(file: URL, source: String, document: Frame.Document)] = []
        var bindings: [Frame.Binding] = []
        var imports: [Frame.Import] = []
        var origin: [String: URL] = [:]
        for file in files {
            do {
                let source = try TextFileReader(file).read().text
                let document = try Frame.parse(source, filePath: file.path)
                parsed.append((file, source, document))
                for binding in document.bindings {
                    if let first = origin[binding.name] {
                        return .invalid(file: file.path, message: "'\(binding.name)' is also declared in \(first.lastPathComponent); names must be unique across files.")
                    }
                    origin[binding.name] = file
                }
                bindings += document.bindings
                imports += document.imports
            } catch {
                return .invalid(file: file.path, message: describe(error))
            }
        }
        // Every failing file is reported: a missing name also fails the files
        // that reach it through a reference, and the declaring file may be any of them.
        var failures: [(file: URL, message: String)] = []
        for (file, source, document) in parsed {
            do {
                try Frame.check(document, in: MailFrame.environment, context: bindings)
            } catch let failure as Frame.TypeFailure {
                failures.append((file, failure.located(in: source).description))
            } catch {
                failures.append((file, describe(error)))
            }
        }
        if let first = failures.first {
            let others = failures.dropFirst().map { "\n\($0.file.path): \($0.message)" }.joined()
            return .invalid(file: first.file.path, message: first.message + others)
        }

        do {
            // A file in a subfolder puts its accounts in that folder's group.
            let root = directory.standardizedFileURL.pathComponents
            let groups = origin.compactMapValues { file -> String? in
                let components = file.standardizedFileURL.pathComponents
                guard components.count > root.count + 1, Array(components.prefix(root.count)) == root else {
                    return nil
                }
                return components[root.count]
            }
            let accounts = try MailAccounts(
                document: Frame.Document(imports: imports, bindings: bindings),
                environment: environment,
                groups: groups
            )
            try accounts.validateProfiles()
            return .loaded(accounts)
        } catch {
            // Fields start with their binding's name; report the file that declares it.
            let field: String? = {
                if case .invalid(let field, _) = error as? MailAccounts.Failure { return field }
                return nil
            }()
            let binding = field.flatMap { $0.split(whereSeparator: { ".[".contains($0) }).first.map(String.init) }
            let file = binding.flatMap { origin[$0] }?.path ?? directory.path
            return .invalid(file: file, message: describe(error))
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
