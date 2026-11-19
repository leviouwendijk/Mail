import Foundation
import IMAP
import Mail
import MailConnection
import MailFrame

enum EmailCLI {}

enum EmailCLIError: Error, LocalizedError {
    case notConfigured(directory: String)
    case invalid(file: String, message: String)
    case unknownAccount(String, known: [String])
    case cannotRead(String, reason: String?)
    case cannotSend(String, reason: String?)
    case unknownIdentity(String, known: [String])
    case invalidAddress(String)
    case invalidDate(String)
    case missing(String)
    case notFound(uid: Int, mailbox: String)
    case declined

    var errorDescription: String? {
        switch self {
        case .notConfigured(let directory):
            return "No mail configuration in \(directory). Start from the example: email example > \(directory)/accounts.frame"
        case .invalid(let file, let message):
            return "\(file): \(message)"
        case .unknownAccount(let name, let known):
            return "No account '\(name)'; known: \(known.joined(separator: ", "))."
        case .cannotRead(let account, let reason):
            return reason.map { "Account '\(account)' cannot be read: \($0)." } ?? "Account '\(account)' has no IMAP server."
        case .cannotSend(let account, let reason):
            return reason.map { "Account '\(account)' cannot send: \($0)." } ?? "Account '\(account)' has no SMTP server."
        case .unknownIdentity(let address, let known):
            return "The account does not send as \(address); its identities: \(known.joined(separator: ", "))."
        case .invalidAddress(let address):
            return "'\(address)' is not a valid address."
        case .invalidDate(let date):
            return "'\(date)' is not a yyyy-MM-dd date."
        case .missing(let message):
            return message
        case .notFound(let uid, let mailbox):
            return "No message with UID \(uid) in \(mailbox)."
        case .declined:
            return "Not sent."
        }
    }
}

extension EmailCLI {
    static func writeError(
        _ error: any Error
    ) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        FileHandle.standardError.write(Data("email: \(message)\n".utf8))
    }

    /// The configuration in `directory`, or the default location.
    static func accounts(
        directory: String? = nil
    ) throws -> MailAccounts {
        let state = directory
            .map { MailConfiguration.state(directory: URL(fileURLWithPath: expandingTilde($0), isDirectory: true)) }
            ?? MailConfiguration.state()
        switch state {
        case .loaded(let accounts):
            return accounts
        case .missing(let directory):
            throw EmailCLIError.notConfigured(directory: directory)
        case .invalid(let file, let message):
            throw EmailCLIError.invalid(file: file, message: message)
        }
    }

    /// The configuration and the access profile a command runs under.
    static func scope(
        directory: String?,
        access: String?
    ) throws -> (MailAccounts, MailAccess) {
        let accounts = try self.accounts(directory: directory)
        return (accounts, try accounts.access(named: access))
    }

    /// `name`'s account, or the first the profile can see.
    static func account(
        _ name: String?,
        in accounts: MailAccounts,
        access: MailAccess = .unrestricted
    ) throws -> MailAccounts.Account {
        guard let name, !name.isEmpty else {
            guard let account = access.visibleAccounts(in: accounts).first else {
                throw EmailCLIError.missing("No account is accessible.")
            }
            return account
        }
        try access.check(account: name)
        guard let account = accounts.account(named: name) else {
            throw EmailCLIError.unknownAccount(name, known: access.visibleAccounts(in: accounts).map(\.identifier))
        }
        return account
    }

    static func imap(
        _ account: MailAccounts.Account,
        in accounts: MailAccounts
    ) throws -> IMAPClient {
        guard let client = accounts.imapClient(for: account) else {
            throw EmailCLIError.cannotRead(account.identifier, reason: account.unavailable[.imap])
        }
        return client
    }

    static func display(
        _ address: NamedAddress
    ) -> String {
        address.name.map { "\($0) <\(address.address.raw)>" } ?? address.address.raw
    }

    static func day(
        _ text: String
    ) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text) else {
            throw EmailCLIError.invalidDate(text)
        }
        return date
    }

    static func shortDate(
        _ date: Date?
    ) -> String {
        guard let date else {
            return "                "
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func addresses(
        _ entries: [String]
    ) throws -> [NamedAddress] {
        try entries.flatMap { entry in
            try entry.split(separator: ",").map { part in
                let text = part.trimmingCharacters(in: .whitespaces)
                guard let parsed = NamedAddress.parseList(text).first else {
                    throw EmailCLIError.invalidAddress(text)
                }
                return parsed
            }
        }
    }

    static func expandingTilde(
        _ path: String
    ) -> String {
        guard path.hasPrefix("~/") else {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/" + path.dropFirst(2)
    }

    /// Reads a yes/no answer from the terminal.
    static func confirm(
        _ question: String
    ) -> Bool {
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return answer == "y" || answer == "yes"
    }
}
