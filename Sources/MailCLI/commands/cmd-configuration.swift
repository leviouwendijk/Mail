import Arguments
import Foundation
import Frame
import Mail
import MailConnection
import MailFrame

struct ConfigurationOptions: Sendable, ArgumentGroup {
    @Opt("config", help: "Configuration directory; ~/.config/mail when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}

enum PathCommand: RunnableArgumentCommand {
    static let name = "path"

    static func components() throws -> [CommandComponentLowerable] {
        [about("Print the configuration directory and the files read from it.")]
    }

    static func run(
        _ invocation: ParsedInvocation
    ) async throws {
        let directory = MailConfiguration.directory()
        print(directory.path)
        let root = directory.standardizedFileURL.path + "/"
        for file in try MailConfiguration.files(in: directory) {
            let path = file.standardizedFileURL.path
            print("  " + (path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path))
        }
    }
}

enum ExampleCommand: RunnableArgumentCommand {
    static let name = "example"

    static func components() throws -> [CommandComponentLowerable] {
        [about("Print a complete example configuration: email example > ~/.config/mail/accounts.frame")]
    }

    static func run(
        _ invocation: ParsedInvocation
    ) async throws {
        print(MailFrame.example)
    }
}

enum ModuleCommand: RunnableArgumentCommand {
    static let name = "module"

    static func components() throws -> [CommandComponentLowerable] {
        [about("Install the Mail Frame module for editor completion and checking of .frame files.")]
    }

    static func run(
        _ invocation: ParsedInvocation
    ) async throws {
        print(try MailFrame.module.install().path)
    }
}

enum CheckCommand: BoundArgumentCommand {
    typealias Options = ConfigurationOptions

    static let name = "check"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Validate the configuration and whether each account's password resolves; connects to nothing."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: ConfigurationOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        for (index, account) in access.visibleAccounts(in: accounts).enumerated() {
            print("\(account.identifier)\(index == 0 ? " (default)" : ""): sending \(access.sending(for: account).rawValue)")
            for (role, service, server) in [("read", MailAccounts.Service.imap, account.imap?.server), ("send", .smtp, account.smtp?.server)] {
                guard let server else {
                    if let reason = account.unavailable[service] {
                        print("  \(role)  UNAVAILABLE: \(reason)")
                    }
                    continue
                }
                var login = "no login"
                if let authentication = server.authentication {
                    do {
                        _ = try await accounts.credentials.resolve(authentication.password).utf8()
                        login = "\(authentication.username), password resolves"
                    } catch {
                        login = "\(authentication.username), password MISSING from \(accounts.source(of: authentication.password))"
                    }
                }
                print("  \(role)  \(server.host):\(server.port) \(EmailCLI.security(server.security)), \(login)")
            }
            for identity in access.identities(of: account) {
                print("  as    \(EmailCLI.display(identity.address))\(identity.signature == nil ? "" : ", signed")")
            }
        }
        for profile in accounts.profiles {
            print("access \(profile.name): " + EmailCLI.describe(profile))
        }
    }
}

enum AccountsCommand: BoundArgumentCommand {
    typealias Options = ConfigurationOptions

    static let name = "accounts"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("List accounts, their identities and servers."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: ConfigurationOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        for account in access.visibleAccounts(in: accounts) {
            print(account.identifier + (account.about.map { " — \($0)" } ?? ""))
            if let imap = account.imap?.server {
                print("  read  \(imap.host):\(imap.port) \(EmailCLI.security(imap.security))")
            }
            if let smtp = account.smtp?.server {
                print("  send  \(smtp.host):\(smtp.port) \(EmailCLI.security(smtp.security)), sending \(access.sending(for: account).rawValue)")
            }
            for (service, reason) in account.unavailable.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("  \(service == .imap ? "read" : "send")  UNAVAILABLE: \(reason)")
            }
            for identity in access.identities(of: account) {
                print("  as    \(EmailCLI.display(identity.address))")
            }
        }
    }
}

extension EmailCLI {
    static func security(
        _ security: MailSecurity
    ) -> String {
        switch security {
        case .implicitTLS: return "tls"
        case .startTLS: return "starttls"
        case .plaintext: return "plaintext"
        }
    }

    static func describe(
        _ profile: MailAccess
    ) -> String {
        let accounts: String = profile.accounts?.joined(separator: ", ") ?? "all"
        let mailboxes: String = profile.mailboxes?.joined(separator: ", ") ?? "all"
        let identities: String = profile.identities?.sorted().joined(separator: ", ") ?? "all"
        let writing: String = profile.maySend ? "may send" : (profile.mayDraft ? "drafts only" : "read only")
        return "accounts \(accounts); mailboxes \(mailboxes); identities \(identities); \(writing)"
    }

    static func describe(
        _ error: any Error
    ) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
