import Arguments
import Foundation
import Frame
import Mail
import MailConnection
import MailFrame

struct ConfigurationOptions: Sendable, ArgumentGroup {
    @Opt("config", help: "Configuration directory; ~/.config/mail when absent.")
    var directory: String?

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
        for file in try MailConfiguration.files(in: directory) {
            print("  \(file.lastPathComponent)")
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
        let accounts = try EmailCLI.accounts(directory: options.directory)
        for (index, account) in accounts.accounts.enumerated() {
            print("\(account.identifier)\(index == 0 ? " (default)" : ""): sending \(account.sending.rawValue)")
            for (role, server) in [("read", account.imap?.server), ("send", account.smtp?.server)] {
                guard let server else {
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
            for identity in account.identities {
                print("  as    \(EmailCLI.display(identity.address))\(identity.signature == nil ? "" : ", signed")")
            }
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
        let accounts = try EmailCLI.accounts(directory: options.directory)
        for account in accounts.accounts {
            print(account.identifier + (account.about.map { " — \($0)" } ?? ""))
            if let imap = account.imap?.server {
                print("  read  \(imap.host):\(imap.port) \(EmailCLI.security(imap.security))")
            }
            if let smtp = account.smtp?.server {
                print("  send  \(smtp.host):\(smtp.port) \(EmailCLI.security(smtp.security)), sending \(account.sending.rawValue)")
            }
            for identity in account.identities {
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
        _ error: any Error
    ) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
