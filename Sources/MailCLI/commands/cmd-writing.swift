import Arguments
import Foundation
import IMAP
import Mail
import MailFrame
import Readers

struct ComposeOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Opt("from", help: "Identity address to send as; the account's first identity when absent.")
    var from: String?

    @Opts("to", help: "Recipient; repeat or separate with commas.")
    var to: [String]

    @Opts("cc", help: "Copy recipient; repeatable.")
    var cc: [String]

    @Opts("bcc", help: "Blind copy recipient; repeatable.")
    var bcc: [String]

    @Opt("subject", short: "s", help: "Subject.")
    var subject: String?

    @Opt("body", short: "b", help: "Body text.")
    var body: String?

    @Opt("body-file", help: "Read the body from a file; - for standard input.")
    var bodyFile: String?

    @Opts("attach", help: "Attach a file; repeatable.")
    var attachments: [String]

    @Flag("yes", short: "y", help: "Do not ask for confirmation.")
    var yes: Bool

    @Opt("config", help: "Configuration directory; ~/.config/mail when absent.")
    var directory: String?

    init() {}

    func compose(
        in accounts: MailAccounts
    ) throws -> (MailAccounts.Account, MailMessage) {
        let account = try EmailCLI.account(self.account, in: accounts)
        let identity = try identity(in: account)
        guard let subject, !subject.isEmpty else {
            throw EmailCLIError.missing("Give a --subject.")
        }
        let to = try EmailCLI.addresses(self.to)
        let cc = try EmailCLI.addresses(self.cc)
        let bcc = try EmailCLI.addresses(self.bcc)
        guard !(to.isEmpty && cc.isEmpty && bcc.isEmpty) else {
            throw EmailCLIError.missing("Give at least one --to, --cc or --bcc.")
        }
        let attached = try attachments.map {
            try MailAttachment.file(at: URL(fileURLWithPath: EmailCLI.expandingTilde($0)))
        }
        let message = identity.message(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: .text(try bodyText()),
            attachments: attached
        )
        return (account, message)
    }

    private func identity(
        in account: MailAccounts.Account
    ) throws -> MailIdentity {
        guard let from, !from.isEmpty else {
            return account.defaultIdentity
        }
        guard let identity = account.identities.first(where: { $0.address.address.raw.caseInsensitiveCompare(from) == .orderedSame }) else {
            throw EmailCLIError.unknownIdentity(from, known: account.identities.map(\.address.address.raw))
        }
        return identity
    }

    private func bodyText() throws -> String {
        if let body {
            return body
        }
        guard let bodyFile else {
            throw EmailCLIError.missing("Give the body with --body or --body-file.")
        }
        if bodyFile == "-" {
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        return try TextFileReader(URL(fileURLWithPath: EmailCLI.expandingTilde(bodyFile))).read().text
    }
}

extension EmailCLI {
    static func summary(
        _ message: MailMessage
    ) -> String {
        var lines = [
            "From:    \(display(message.from))",
            "To:      \(message.to.map(display).joined(separator: ", "))",
        ]
        if !message.cc.isEmpty {
            lines.append("Cc:      \(message.cc.map(display).joined(separator: ", "))")
        }
        if !message.bcc.isEmpty {
            lines.append("Bcc:     \(message.bcc.map(display).joined(separator: ", "))")
        }
        lines.append("Subject: \(message.subject)")
        for attachment in message.attachments {
            lines.append("Attach:  \(attachment.filename) (\(attachment.data.count) bytes)")
        }
        return lines.joined(separator: "\n")
    }

    static func folder(
        _ role: IMAPSpecialUse,
        for account: MailAccounts.Account,
        in session: IMAPSession
    ) async throws -> String? {
        if let configured = account.folders[role] {
            return configured
        }
        return try await session.mailbox(for: role)?.name
    }
}

enum DraftCommand: BoundArgumentCommand {
    typealias Options = ComposeOptions

    static let name = "draft"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Compose a signed message and save it in the account's Drafts folder."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: ComposeOptions,
        invocation: ParsedInvocation
    ) async throws {
        let accounts = try EmailCLI.accounts(directory: options.directory)
        let (account, message) = try options.compose(in: accounts)
        let data = MailRenderer().data(message)
        let folder = try await EmailCLI.imap(account, in: accounts).session { session in
            let folder = try await EmailCLI.folder(.drafts, for: account, in: session) ?? "Drafts"
            try await session.append(data, to: folder, flags: [.draft, .seen])
            return folder
        }
        print("Saved to \(account.identifier)/\(folder):\n\(EmailCLI.summary(message))")
    }
}

enum SendCommand: BoundArgumentCommand {
    typealias Options = ComposeOptions

    static let name = "send"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Compose a signed message, confirm, send it and save a copy in Sent."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: ComposeOptions,
        invocation: ParsedInvocation
    ) async throws {
        let accounts = try EmailCLI.accounts(directory: options.directory)
        var (account, message) = try options.compose(in: accounts)
        guard let smtp = accounts.smtpClient(for: account) else {
            throw EmailCLIError.cannotSend(account.identifier)
        }
        // Fixed before rendering twice, so the Sent copy is the delivered message.
        message.messageID = "\(UUID().uuidString)@\(message.from.address.domain)"
        message.date = Date()

        FileHandle.standardError.write(Data("\(EmailCLI.summary(message))\n".utf8))
        guard options.yes || EmailCLI.confirm("Send?") else {
            throw EmailCLIError.declined
        }

        let delivery = try await smtp.send(message)
        print("Sent to \(delivery.accepted.map(\.raw).joined(separator: ", "))")
        for rejection in delivery.rejected {
            print("Refused \(rejection.recipient.raw): \(rejection.reply)")
        }

        if let imap = accounts.imapClient(for: account) {
            let data = MailRenderer().data(message)
            do {
                let folder = try await imap.session { session -> String? in
                    guard let folder = try await EmailCLI.folder(.sent, for: account, in: session) else {
                        return nil
                    }
                    try await session.append(data, to: folder, flags: [.seen])
                    return folder
                }
                print(folder.map { "Copy saved in \($0)" } ?? "No Sent folder known; no copy saved (set folders.sent).")
            } catch {
                print("Sent, but saving a copy failed: \(EmailCLI.describe(error))")
            }
        }
    }
}
