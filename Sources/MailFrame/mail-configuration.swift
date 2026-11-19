import Foundation
import Frame
import IO
import Path
import Readers
import Roots

/// Where mail configuration lives: every `*.frame` file in `.config/mail/`
/// of every root (Frame's `Roots`: your home first, then each shared root in
/// `~/.config/roots.frame`) and their subdirectories, under any names. Each
/// file starts with `import Mail;`; together they form one configuration, so
/// a binding may reference one declared in another file or another root, in
/// any order. Names must be unique across all files; accounts keep root,
/// then relative-path order, so the default account is the first in your own
/// files. A file in a subfolder puts its accounts in that folder's group; a
/// top-level file of a shared root puts them in the root's group.
public enum MailConfiguration {
    public enum State: Sendable {
        case loaded(MailAccounts)
        /// No `.frame` file in any root.
        case missing(directory: String)
        case invalid(file: String, message: String)
    }

    /// One directory of mail configuration.
    public struct Source: Sendable, Hashable {
        /// The root it belongs to: `private`, or a shared root's name.
        public let root: String
        public let directory: URL
        /// The group of accounts in its top-level files.
        public let group: String?

        public init(
            root: String,
            directory: URL,
            group: String? = nil
        ) {
            self.root = root
            self.directory = directory
            self.group = group
        }
    }

    public static let location = RootLocation.config("mail")

    /// Your own mail directory: `$XDG_CONFIG_HOME/mail`, else `~/.config/mail`.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Roots.home.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("mail", isDirectory: true)
    }

    /// Your own mail directory, then each shared root's `.config/mail/` that exists.
    public static func sources(
        roots: RootSet = Roots.load(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Source] {
        [Source(root: Root.privateName, directory: directory(environment: environment))]
            + roots.shared
                .map { Source(root: $0.name, directory: $0.url(location), group: $0.name) }
                .filter { FileSystem.default.exists($0.directory) }
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

    /// Every root's configuration, as one.
    public static func state(
        roots: RootSet = Roots.load(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> State {
        state(sources: sources(roots: roots, environment: environment), environment: environment)
    }

    /// One directory alone, such as `email --config <dir>`.
    public static func state(
        directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> State {
        state(sources: [Source(root: Root.privateName, directory: directory)], environment: environment)
    }

    public static func state(
        sources: [Source],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> State {
        // A synced folder may hold files not downloaded yet or conflict copies;
        // loading around them would silently drop or double accounts.
        for source in sources {
            let issues = RootFileIssues.scan(source.directory)
            if let first = issues.notDownloaded.first ?? issues.conflictCopies.first {
                return .invalid(file: first.path, message: issues.descriptions.joined(separator: "\n"))
            }
        }

        var files: [(file: URL, source: Source)] = []
        for source in sources {
            do {
                files += try Self.files(in: source.directory).map { ($0, source) }
            } catch {
                return .invalid(file: source.directory.path, message: String(describing: error))
            }
        }
        guard !files.isEmpty else {
            return .missing(directory: sources.first?.directory.path ?? directory().path)
        }

        // Every file is parsed on its own; each is then checked with all the
        // others' bindings in scope, so references cross files in any order.
        var parsed: [(file: URL, source: String, document: Frame.Document)] = []
        var bindings: [Frame.Binding] = []
        var imports: [Frame.Import] = []
        var origin: [String: URL] = [:]
        var groups: [String: String] = [:]
        for (file, location) in files {
            do {
                let source = try TextFileReader(file).read().text
                let document = try Frame.parse(source, filePath: file.path)
                parsed.append((file, source, document))
                for binding in document.bindings {
                    if let first = origin[binding.name] {
                        return .invalid(file: file.path, message: "'\(binding.name)' is also declared in \(Self.display(first, sources: sources)); names must be unique across files and roots.")
                    }
                    origin[binding.name] = file
                    if let group = Self.group(of: file, in: location) {
                        groups[binding.name] = group
                    }
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
            let file = binding.flatMap { origin[$0] }?.path ?? sources.first?.directory.path ?? ""
            return .invalid(file: file, message: describe(error))
        }
    }

    /// A subfolder's name, else the source's own group.
    static func group(
        of file: URL,
        in source: Source
    ) -> String? {
        let root = source.directory.standardizedFileURL.pathComponents
        let components = file.standardizedFileURL.pathComponents
        guard components.count > root.count + 1, Array(components.prefix(root.count)) == root else {
            return source.group
        }
        return components[root.count]
    }

    /// `a-home.frame` in your own directory; `hondenmeesters: hondenmeesters/accounts.frame` in a shared root.
    static func display(
        _ file: URL,
        sources: [Source]
    ) -> String {
        let path = file.standardizedFileURL.path
        for source in sources {
            let prefix = source.directory.standardizedFileURL.path + "/"
            if path.hasPrefix(prefix) {
                let relative = String(path.dropFirst(prefix.count))
                return source.root == Root.privateName ? relative : "\(source.root): \(relative)"
            }
        }
        return path
    }

    static func describe(
        _ error: any Error
    ) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// The configuration of every root, reloaded only when `roots.frame` or a
/// file in any root is added, removed or modified, so a long-running host
/// sees edits, including a teammate's in a shared root.
public final class MailConfigurationStore: @unchecked Sendable {
    public static let standard = MailConfigurationStore()

    /// One directory instead of the roots, as for tests or `--config`.
    public let directory: URL?
    private let environment: [String: String]
    private let lock = NSLock()
    private var signature: [String: Date?]?
    private var cached: MailConfiguration.State?

    public init(
        directory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.directory = directory
        self.environment = environment
    }

    public func sources() -> [MailConfiguration.Source] {
        if let directory {
            return [MailConfiguration.Source(root: Root.privateName, directory: directory)]
        }
        return MailConfiguration.sources(roots: Roots.load(file: Roots.file(environment: environment)), environment: environment)
    }

    public func state() -> MailConfiguration.State {
        let sources = sources()
        let current = currentSignature(sources)
        lock.lock()
        defer { lock.unlock() }
        if let cached, signature == current {
            return cached
        }
        let state = MailConfiguration.state(sources: sources, environment: environment)
        cached = state
        signature = current
        return state
    }

    private func currentSignature(
        _ sources: [MailConfiguration.Source]
    ) -> [String: Date?] {
        var files = sources.flatMap { (try? MailConfiguration.files(in: $0.directory)) ?? [] }
        if directory == nil {
            files.append(Roots.file(environment: environment))
        }
        return Dictionary(files.map { file in
            (file.path, (try? FileInspector(file).inspect())?.modifiedAt)
        }, uniquingKeysWith: { first, _ in first })
    }
}
