import Arguments
import Foundation
import IMAP
import Mail
import MailFrame
import MailIndex

enum PlanCommand: BoundArgumentCommand {
    typealias Options = PlanOptions

    static let name = "plan"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Propose one server change for messages picked from the index (--suspicious, or by sender, domain, list, age) and store it as a plan; nothing changes until `email apply <id>`."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: PlanOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        let index = try EmailCLI.existingIndex(options.index, account: account)
        let action = try options.action()

        let targets: [MailPlan.Target]
        let reason: String
        if options.suspicious {
            let policy = MailSuspicionPolicy(
                trustedDomains: Set(options.trusted),
                ownDomains: EmailCLI.ownDomains(accounts),
                threshold: options.threshold
            )
            targets = try await index.targets(try await index.suspicious(policy, filter: options.filter()))
            reason = options.reason ?? "suspicious, score \(options.threshold)+"
        } else {
            let filter = options.filter()
            guard filter.sender != nil || filter.domain != nil || filter.listID != nil else {
                throw EmailCLIError.missing("Pick messages with --suspicious, --sender, --domain or --list (narrowed by --mailbox, --older-than, --unread).")
            }
            targets = try await index.targets(filter)
            reason = options.reason ?? "selected"
        }
        for mailbox in Set(targets.map(\.mailbox)) {
            try access.check(mailbox: mailbox)
        }
        guard !targets.isEmpty else {
            print("Nothing matches; no plan stored.")
            return
        }

        let plan = MailPlan(steps: [.init(action, reason: reason, targets: targets)])
        try await index.save(plan)
        print("plan \(plan.id): \(plan.summary)")
        for preview in try await index.previews(targets, limit: options.show) {
            print("  \(EmailCLI.dayText(preview.receivedAt))  \(preview.target.mailbox):\(preview.target.uid)  \(preview.fromAddress ?? "?")  \(preview.subject ?? "")")
        }
        if targets.count > options.show {
            print("  … and \(targets.count - options.show) more")
        }
        print("apply with: email apply -a \(account.identifier) \(plan.id)")
    }
}

struct PlanOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Flag("suspicious", help: "The messages `email review` shows (same scoring and decisions).")
    var suspicious: Bool

    @Opt("threshold", default: 50, help: "With --suspicious: the lowest score included.")
    var threshold: Int

    @Opts("trusted", help: "With --suspicious: a vendor domain treated as known (repeatable).")
    var trusted: [String]

    @Opt("sender", help: "Messages from this address.")
    var sender: String?

    @Opt("domain", help: "Messages from this domain or its subdomains.")
    var domain: String?

    @Opt("list", help: "Messages of this mailing list (List-Id).")
    var list: String?

    @Opt("mailbox", short: "m", help: "Only this mailbox.")
    var mailbox: String?

    @Opt("older-than", help: "Only messages received more than this many days ago.")
    var olderThan: Int?

    @Opt("days", help: "Only messages received in the last this many days.")
    var days: Int?

    @Flag("unread", help: "Only unread messages.")
    var unread: Bool

    @Opt("move-to", help: "Move them to this mailbox (created when missing).")
    var moveTo: String?

    @Opt("flag", help: "Add this flag or keyword, such as $Suspicious or \\Flagged.")
    var flag: String?

    @Opt("unflag", help: "Remove this flag or keyword.")
    var unflag: String?

    @Opt("label", help: "Add this Gmail label.")
    var label: String?

    @Opt("unlabel", help: "Remove this Gmail label (\\Inbox archives).")
    var unlabel: String?

    @Opt("reason", help: "Why, kept with the plan.")
    var reason: String?

    @Opt("show", default: 10, help: "Messages to list.")
    var show: Int

    @Opt("index", help: "Index file; ~/.local/share/mail/index/<account>.sqlite when absent.")
    var index: String?

    @Opt("config", help: "One configuration directory alone; every root's .config/mail (your own, then shared roots in ~/.config/roots.frame) when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}

    func action() throws -> MailAction {
        let actions: [MailAction] = [
            moveTo.map { .move(to: $0) },
            flag.map { .addFlags([$0]) },
            unflag.map { .removeFlags([$0]) },
            label.map { .addLabels([$0]) },
            unlabel.map { .removeLabels([$0]) },
        ].compactMap { $0 }
        guard actions.count == 1, let action = actions.first else {
            throw EmailCLIError.missing("Give exactly one of --move-to, --flag, --unflag, --label, --unlabel.")
        }
        return action
    }

    func filter() -> MailIndexFilter {
        var filter = MailIndexFilter(mailbox: mailbox, sender: sender, domain: domain, listID: list)
        if let olderThan {
            filter.receivedBefore = Date().addingTimeInterval(-Double(olderThan) * 86_400)
        }
        if let days {
            filter.receivedSince = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        if unread {
            filter.unread = true
        }
        return filter
    }
}

enum PlansCommand: BoundArgumentCommand {
    typealias Options = PlanReferenceOptions

    static let name = "plans"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Stored plans of an account, newest first, with whether they were applied or undone."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: PlanReferenceOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        let index = try EmailCLI.existingIndex(options.index, account: account)
        for record in try await index.plans(limit: 30) {
            let state = record.undoneAt.map { "undone \(EmailCLI.dayText($0))" }
                ?? record.appliedAt.map { "applied \(EmailCLI.dayText($0))" }
                ?? "proposed"
            print("\(record.plan.id)  \(state.padding(toLength: 18, withPad: " ", startingAt: 0))  \(record.plan.summary)")
        }
    }
}

enum ApplyCommand: BoundArgumentCommand {
    typealias Options = PlanReferenceOptions

    static let name = "apply"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Apply a stored plan on the server: each message is checked again (mailbox numbering, Message-ID) and skipped when it changed; results are journaled for `email undo`, then the index is re-synced. Asks first unless --yes. Never deletes."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: PlanReferenceOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        try access.checkDrafting()
        let index = try EmailCLI.existingIndex(options.index, account: account)
        let id = options.id
        guard !id.isEmpty, let record = try await index.plan(id) else {
            throw EmailCLIError.missing("Name a plan from `email plans -a \(account.identifier)`.")
        }
        guard record.appliedAt == nil else {
            throw EmailCLIError.missing("Plan \(id) was already applied; `email undo` reverses it.")
        }
        for step in record.plan.steps {
            for mailbox in Set(step.targets.map(\.mailbox)) {
                try access.check(mailbox: mailbox)
            }
            if case .move(let destination) = step.action {
                try access.check(mailbox: destination)
            }
        }
        print("\(account.identifier): \(record.plan.summary)")
        guard options.yes || EmailCLI.confirm("Apply on the server?") else {
            throw EmailCLIError.declined
        }
        let report = try await EmailCLI.imap(account, in: accounts).session { session in
            try await MailPlanExecutor(index: index, session: session).execute(record.plan)
        }
        EmailCLI.print(report)
    }
}

enum UndoCommand: BoundArgumentCommand {
    typealias Options = PlanReferenceOptions

    static let name = "undo"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Reverse an applied plan from its journal: moved messages go back, flags and labels come off. Checked like apply; asks first unless --yes."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: PlanReferenceOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        try access.checkDrafting()
        let index = try EmailCLI.existingIndex(options.index, account: account)
        let id = options.id
        guard !id.isEmpty, let record = try await index.plan(id), record.appliedAt != nil else {
            throw EmailCLIError.missing("Name an applied plan from `email plans -a \(account.identifier)`.")
        }
        guard record.undoneAt == nil else {
            throw EmailCLIError.missing("Plan \(id) was already undone.")
        }
        let undo = try await index.undoPlan(for: id)
        guard undo.count > 0 else {
            throw EmailCLIError.missing("Plan \(id) changed nothing that can be reversed.")
        }
        print("\(account.identifier): \(undo.summary)")
        guard options.yes || EmailCLI.confirm("Undo on the server?") else {
            throw EmailCLIError.declined
        }
        let report = try await EmailCLI.imap(account, in: accounts).session { session in
            try await MailPlanExecutor(index: index, session: session).execute(undo)
        }
        EmailCLI.print(report)
    }
}

struct PlanReferenceOptions: Sendable, ArgumentGroup {
    @Arg("id", help: "The plan, as `email plans` lists it.", default: "")
    var id: String

    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Flag("yes", short: "y", help: "Do not ask first.")
    var yes: Bool

    @Opt("index", help: "Index file; ~/.local/share/mail/index/<account>.sqlite when absent.")
    var index: String?

    @Opt("config", help: "One configuration directory alone; every root's .config/mail (your own, then shared roots in ~/.config/roots.frame) when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}

extension EmailCLI {
    static func existingIndex(
        _ path: String?,
        account: MailAccounts.Account
    ) throws -> MailIndex {
        let url = indexURL(path, account: account)
        guard MailIndex.exists(at: url) else {
            throw EmailCLIError.missing("No index for \(account.identifier) yet; run `email index -a \(account.identifier)`.")
        }
        return try MailIndex(url: url)
    }

    /// Domains of every configured identity, except free-mail providers.
    static func ownDomains(
        _ accounts: MailAccounts
    ) -> Set<String> {
        Set(
            accounts.accounts
                .flatMap(\.identities)
                .map { String($0.address.address.domain).lowercased() }
                .filter { !MailSuspicionPolicy.freemailDomains.contains($0) }
        )
    }

    static func print(
        _ report: MailPlanReport
    ) {
        Swift.print("applied \(report.applied), skipped \(report.skipped.count)\(report.touched.isEmpty ? "" : "; re-synced \(report.touched.joined(separator: ", "))")")
        for skip in report.skipped.prefix(20) {
            Swift.print("  skipped \(skip.target.mailbox):\(skip.target.uid): \(skip.reason)")
        }
    }
}
