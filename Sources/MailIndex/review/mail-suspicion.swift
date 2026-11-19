import Foundation
import IMAP
import SQLite

/// One reason a message looks suspicious.
public enum MailSuspicionSignal: String, Sendable, CaseIterable {
    /// Payment wording in the subject or an attachment name.
    case paymentRequest
    /// Asks for payment and the sender is not a trusted vendor.
    case unknownVendor
    /// Never written to.
    case stranger
    /// Hardly any mail from this domain, ever.
    case rareSender
    case dmarcFail
    case spfFail
    case dkimFail
    /// Replies would go to another domain.
    case replyElsewhere
    /// Bounces go to another domain (common for mail services; weak).
    case returnPathElsewhere
    /// The domain resembles, or carries the name of, one of your domains or a trusted vendor.
    case lookalike
    /// An attachment type that carries code or hides content (zip, html, executables).
    case riskyAttachment
    /// The sender or domain was blocked in review.
    case blocked
}

/// What the score is measured against. Weights are a starting point, tuned on
/// real mail.
public struct MailSuspicionPolicy: Sendable, Equatable {
    /// Vendor and contact domains known to be real (owner context, review trust).
    public var trustedDomains: Set<String>
    /// Your own domains, from the accounts' identities.
    public var ownDomains: Set<String>
    /// Reviewed at or above this score.
    public var threshold: Int
    public var weights: [MailSuspicionSignal: Int]
    /// Lowercased words that mark a payment request (Dutch and English).
    public var paymentTerms: [String]
    /// At most this many messages from a domain counts as rare.
    public var rareCount: Int

    public init(
        trustedDomains: Set<String> = [],
        ownDomains: Set<String> = [],
        threshold: Int = 50,
        weights: [MailSuspicionSignal: Int] = MailSuspicionPolicy.defaultWeights,
        paymentTerms: [String] = MailSuspicionPolicy.defaultPaymentTerms,
        rareCount: Int = 2
    ) {
        self.trustedDomains = Set(trustedDomains.map { $0.lowercased() })
        self.ownDomains = Set(ownDomains.map { $0.lowercased() })
        self.threshold = threshold
        self.weights = weights
        self.paymentTerms = paymentTerms
        self.rareCount = rareCount
    }

    public static let defaultWeights: [MailSuspicionSignal: Int] = [
        .paymentRequest: 20,
        .unknownVendor: 20,
        .stranger: 10,
        .rareSender: 10,
        .dmarcFail: 25,
        .spfFail: 10,
        .dkimFail: 10,
        .replyElsewhere: 15,
        .returnPathElsewhere: 5,
        .lookalike: 35,
        .riskyAttachment: 25,
        .blocked: 100,
    ]

    public static let defaultPaymentTerms = [
        "factuur", "facturen", "invoice", "betaling", "betaal", "betalen", "payment", "pay now",
        "vervaldatum", "verloopt", "expir", "herinnering", "aanmaning", "reminder", "openstaand",
        "outstanding", "overdue", "incasso", "iban", "rekening", "renewal", "verlenging", "verlengen",
        "domein", "domain", "registratie", "registration", "abonnement", "subscription",
    ]

    public static let riskyAttachmentExtensions: Set<String> = [
        "zip", "rar", "7z", "iso", "img", "html", "htm", "shtml", "svg", "exe", "scr", "js", "vbs",
        "bat", "cmd", "msi", "jar", "docm", "xlsm", "pptm", "lnk", "hta",
    ]
}

/// A message's suspicion score with every reason that contributed.
public struct MailSuspicion: Sendable, Equatable {
    public struct Reason: Sendable, Equatable {
        public let signal: MailSuspicionSignal
        public let weight: Int
        public let detail: String
    }

    public let mailbox: String
    public let uid: IMAPUID
    public let messageID: String?
    public let fromAddress: String?
    public let fromName: String?
    public let fromDomain: String?
    public let subject: String?
    public let receivedAt: Date?
    public let attachmentNames: [String]
    public let reasons: [Reason]

    public var score: Int {
        reasons.reduce(0) { $0 + $1.weight }
    }
}

extension MailIndex {
    /// Scores received messages against `policy`, highest first, and returns
    /// those at or above its threshold. Trusted senders and domains, and messages
    /// already dismissed or recorded, are skipped; blocked ones always show.
    public func suspicious(
        _ policy: MailSuspicionPolicy,
        filter: MailIndexFilter = MailIndexFilter(),
        limit: Int? = nil
    ) throws -> [MailSuspicion] {
        let decisions = try self.decisions()
        func values(_ scope: MailDecision.Scope, _ verdicts: Set<MailDecision.Verdict>) -> Set<String> {
            Set(decisions.filter { $0.scope == scope && verdicts.contains($0.verdict) }.map(\.value))
        }
        let trustedSenders = values(.sender, [.trust])
        let trustedDomains = values(.domain, [.trust]).union(policy.trustedDomains)
        let blockedSenders = values(.sender, [.block])
        let blockedDomains = values(.domain, [.block])
        let settledMessages = values(.message, [.dismiss, .record, .trust])
        let blockedMessages = values(.message, [.block])

        let (condition, bindings) = filter.clause()
        let rows = try database.query(
            """
            WITH domains AS (SELECT from_domain, COUNT(*) AS n FROM messages WHERE is_sent = 0 GROUP BY from_domain)
            SELECT m.mailbox, m.uid, m.message_id, m.from_address, m.from_name, m.from_domain,
                   m.reply_to_domain, m.return_path_domain, m.subject, m.received_at,
                   m.spf, m.dkim, m.dmarc, m.attachment_names, COALESCE(d.n, 0),
                   EXISTS (SELECT 1 FROM correspondents c WHERE c.address = m.from_address),
                   EXISTS (SELECT 1 FROM correspondents c WHERE c.domain = m.from_domain)
            FROM messages m LEFT JOIN domains d ON d.from_domain = m.from_domain
            WHERE \(condition)
            """,
            bindings
        )

        let known = policy.ownDomains.union(trustedDomains)
        var results: [MailSuspicion] = []
        for row in rows {
            let messageID = row[2].string
            let address = row[3].string
            let domain = row[5].string
            if let messageID, settledMessages.contains(messageID) {
                continue
            }
            let blocked = (messageID.map(blockedMessages.contains) ?? false)
                || (address.map(blockedSenders.contains) ?? false)
                || (domain.map { MailDomain.isWithin($0, blockedDomains) } ?? false)
            let trusted = (address.map(trustedSenders.contains) ?? false)
                || (domain.map { MailDomain.isWithin($0, trustedDomains) || MailDomain.isWithin($0, policy.ownDomains) } ?? false)
            if trusted && !blocked {
                continue
            }

            let subject = row[8].string
            let attachments = row[13].string?.split(separator: "\n").map(String.init) ?? []
            var reasons: [MailSuspicion.Reason] = []
            func add(_ signal: MailSuspicionSignal, _ detail: String) {
                if let weight = policy.weights[signal], weight != 0 {
                    reasons.append(.init(signal: signal, weight: weight, detail: detail))
                }
            }

            if blocked {
                add(.blocked, "blocked in review")
            }
            // Someone you wrote to (or their domain) is an existing relationship.
            let correspondent = (row[15].int ?? 0) != 0 || (row[16].int ?? 0) != 0
            let wording = ([subject ?? ""] + attachments).joined(separator: " ").lowercased()
            let terms = policy.paymentTerms.filter { wording.contains($0) }
            if !terms.isEmpty {
                add(.paymentRequest, "payment wording: \(terms.prefix(3).joined(separator: ", "))")
                if !correspondent {
                    add(.unknownVendor, "\(domain ?? "sender") is not a known vendor")
                }
            }
            if !correspondent {
                add(.stranger, "never written to")
            }
            let domainCount = row[14].int ?? 0
            if !correspondent && domainCount <= policy.rareCount {
                add(.rareSender, domainCount <= 1 ? "first mail from \(domain ?? "this domain")" : "\(domainCount) mails from \(domain ?? "this domain") ever")
            }
            for (signal, column, method) in [(MailSuspicionSignal.dmarcFail, 12, "dmarc"), (.spfFail, 10, "spf"), (.dkimFail, 11, "dkim")] {
                if let result = row[column].string, ["fail", "softfail", "permerror"].contains(result) {
                    add(signal, "\(method)=\(result)")
                }
            }
            if let domain, let replyTo = row[6].string, !MailDomain.related(domain, replyTo) {
                add(.replyElsewhere, "replies go to \(replyTo)")
            }
            if let domain, let returnPath = row[7].string, !MailDomain.related(domain, returnPath) {
                add(.returnPathElsewhere, "bounces go to \(returnPath)")
            }
            if let domain, let imitated = MailDomain.imitates(domain, known) {
                add(.lookalike, "\(domain) imitates \(imitated)")
            }
            let risky = attachments.filter { name in
                name.split(separator: ".").last.map { MailSuspicionPolicy.riskyAttachmentExtensions.contains($0.lowercased()) } ?? false
            }
            if !risky.isEmpty {
                add(.riskyAttachment, "attachment \(risky.prefix(2).joined(separator: ", "))")
            }

            let suspicion = MailSuspicion(
                mailbox: row[0].string ?? "",
                uid: IMAPUID(UInt32(row[1].int ?? 0)),
                messageID: messageID,
                fromAddress: address,
                fromName: row[4].string,
                fromDomain: domain,
                subject: subject,
                receivedAt: row[9].double.map(Date.init(timeIntervalSince1970:)),
                attachmentNames: attachments,
                reasons: reasons
            )
            if suspicion.score >= policy.threshold {
                results.append(suspicion)
            }
        }
        results.sort { ($0.score, $0.receivedAt ?? .distantPast) > ($1.score, $1.receivedAt ?? .distantPast) }
        return limit.map { Array(results.prefix($0)) } ?? results
    }
}

/// Domain comparisons without a public-suffix list: good enough for `.nl`,
/// `.com` and friends; `co.uk`-style suffixes compare one label too short.
package enum MailDomain {
    /// The last two labels: `mail.shop.example.nl` → `example.nl`.
    package static func registrable(
        _ domain: String
    ) -> String {
        domain.lowercased().split(separator: ".").suffix(2).joined(separator: ".")
    }

    package static func related(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        registrable(lhs) == registrable(rhs)
    }

    /// `domain` is one of `domains` or a subdomain of one.
    package static func isWithin(
        _ domain: String,
        _ domains: Set<String>
    ) -> Bool {
        let domain = domain.lowercased()
        return domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// The known domain `domain` resembles without being it: within two edits,
    /// or carrying its name (`hondenmeesters-betaling.com`).
    package static func imitates(
        _ domain: String,
        _ known: Set<String>
    ) -> String? {
        let candidate = registrable(domain)
        let candidateName = candidate.split(separator: ".").first.map(String.init) ?? candidate
        for original in known.sorted() {
            let target = registrable(original)
            guard candidate != target else {
                continue
            }
            let name = target.split(separator: ".").first.map(String.init) ?? target
            if name.count >= 5 && (candidateName.contains(name) || distance(candidateName, name) <= (name.count >= 8 ? 2 : 1)) {
                return original
            }
        }
        return nil
    }

    /// Levenshtein distance.
    package static func distance(
        _ lhs: String,
        _ rhs: String
    ) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
