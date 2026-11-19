import Arguments
import Foundation
import IMAP
import Mail
import MailFrame
import MailIndex

enum ReviewCommand: BoundArgumentCommand {
    typealias Options = ReviewOptions

    static let name = "review"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Suspicious mail in an account's index (fake invoices, phishing), with the reasons; nothing changes on the server. Decide with --trust/--block (a sender or domain) or --record/--dismiss (a UID)."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: ReviewOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        let url = EmailCLI.indexURL(options.index, account: account)
        guard MailIndex.exists(at: url) else {
            throw EmailCLIError.missing("No index for \(account.identifier) yet; run `email index -a \(account.identifier)`.")
        }
        let index = try MailIndex(url: url)

        if let decision = try await decision(options, index: index) {
            try await index.decide(decision)
            print("\(decision.verdict.rawValue) \(decision.scope.rawValue) \(decision.value)")
            return
        }
        if options.decisions {
            for decision in try await index.decisions() {
                print("\(EmailCLI.dayText(decision.decidedAt))  \(decision.verdict.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(decision.scope.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(decision.value)\(decision.note.map { "  — \($0)" } ?? "")")
            }
            return
        }

        let own = Set(
            accounts.accounts
                .flatMap(\.identities)
                .map { String($0.address.address.domain).lowercased() }
                .filter { !MailSuspicionPolicy.freemailDomains.contains($0) }
        )
        let policy = MailSuspicionPolicy(
            trustedDomains: Set(options.trusted),
            ownDomains: own,
            threshold: options.threshold
        )
        var filter = MailIndexFilter(mailbox: options.mailbox)
        if let days = options.days {
            filter.receivedSince = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        let suspects = try await index.suspicious(policy, filter: filter)
        for suspect in suspects.prefix(max(1, options.limit)) {
            let from = suspect.fromName.map { "\($0) <\(suspect.fromAddress ?? "")>" } ?? suspect.fromAddress ?? "?"
            print("⚠ \(String(suspect.score).padding(toLength: 4, withPad: " ", startingAt: 0)) \(EmailCLI.dayText(suspect.receivedAt))  \(suspect.mailbox):\(suspect.uid.rawValue)  \(from)")
            print("         \(suspect.subject ?? "(no subject)")")
            if !suspect.attachmentNames.isEmpty {
                print("         attached: \(suspect.attachmentNames.joined(separator: ", "))")
            }
            print("         " + suspect.reasons.map(\.detail).joined(separator: " · "))
        }
        FileHandle.standardError.write(Data("\(min(suspects.count, max(1, options.limit))) of \(suspects.count) at or above \(options.threshold)\n".utf8))
    }

    static func decision(
        _ options: ReviewOptions,
        index: MailIndex
    ) async throws -> MailDecision? {
        let note = options.note
        if let value = options.trust ?? options.block {
            let verdict: MailDecision.Verdict = options.trust != nil ? .trust : .block
            return MailDecision(verdict, value.contains("@") ? .sender : .domain, value, note: note)
        }
        guard let uid = options.record ?? options.dismiss else {
            return nil
        }
        let mailbox = options.mailbox ?? "INBOX"
        guard let messageID = try await index.messageID(IMAPUID(UInt32(uid)), in: mailbox) else {
            throw EmailCLIError.missing("No indexed message \(uid) in \(mailbox) with a Message-ID.")
        }
        return MailDecision(options.record != nil ? .record : .dismiss, .message, messageID, note: note)
    }
}

struct ReviewOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Opt("limit", short: "n", default: 30, help: "Suspects to show.")
    var limit: Int

    @Opt("threshold", default: 50, help: "Lowest score shown.")
    var threshold: Int

    @Opt("days", help: "Only mail received in the last this many days.")
    var days: Int?

    @Opt("mailbox", short: "m", help: "Only this mailbox; for --record/--dismiss, the UID's mailbox (INBOX when absent).")
    var mailbox: String?

    @Opts("trusted", help: "A vendor domain to treat as known for this run (repeatable).")
    var trusted: [String]

    @Opt("trust", help: "Trust a sender (address) or domain from now on.")
    var trust: String?

    @Opt("block", help: "Block a sender (address) or domain: always shown, at the top.")
    var block: String?

    @Opt("record", help: "Mark this UID a genuine record (invoice, contract).")
    var record: Int?

    @Opt("dismiss", help: "Mark this UID harmless; stop showing it.")
    var dismiss: Int?

    @Opt("note", help: "Why, kept with the decision.")
    var note: String?

    @Flag("decisions", help: "List the decisions made so far.")
    var decisions: Bool

    @Opt("index", help: "Index file; ~/.local/share/mail/index/<account>.sqlite when absent.")
    var index: String?

    @Opt("config", help: "One configuration directory alone; every root's .config/mail (your own, then shared roots in ~/.config/roots.frame) when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}
