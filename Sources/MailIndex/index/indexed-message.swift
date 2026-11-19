import Foundation
import IMAP
import Mail

/// One message as the index keeps it: who, when, how big, read state, list and
/// authentication headers, and attachments. Never the body.
public struct IndexedMessage: Sendable, Equatable {
    public let mailbox: String
    public let uid: IMAPUID
    public let messageID: String?
    public let gmailID: String?
    public let threadID: String?
    /// Lowercased.
    public let fromAddress: String?
    public let fromName: String?
    /// Lowercased.
    public let fromDomain: String?
    public let replyToDomain: String?
    public let returnPathDomain: String?
    /// To, cc and bcc, lowercased.
    public let recipients: [String]
    public let subject: String?
    public let sentAt: Date?
    public let receivedAt: Date?
    public let size: Int?
    public let flags: Set<IMAPFlag>
    public let listID: String?
    public let unsubscribable: Bool
    public let precedence: String?
    public let autoSubmitted: String?
    /// `pass`, `fail`, `softfail`, `none`… from `Authentication-Results`, when present.
    public let spf: String?
    public let dkim: String?
    public let dmarc: String?
    public let attachments: [IMAPBodyPart]
    public let labels: [String]
    /// In a Sent mailbox, or carrying Gmail's `\Sent` label.
    public let isSent: Bool

    /// The header fields the index asks for with each summary.
    public static let headerFields = [
        "List-Id", "List-Unsubscribe", "Precedence", "Auto-Submitted", "Authentication-Results", "Return-Path",
    ]

    public init(
        _ summary: IMAPMessageSummary,
        mailbox: String,
        sentMailbox: Bool
    ) {
        let envelope = summary.envelope
        let from = envelope?.from.first ?? envelope?.sender.first
        let headers = summary.headers
        let authentication = headers?.all("Authentication-Results").joined(separator: "; ") ?? ""

        self.mailbox = mailbox
        self.uid = summary.uid
        self.messageID = envelope?.messageID
        self.gmailID = summary.gmail?.messageID
        self.threadID = summary.gmail?.threadID
        self.fromAddress = from.map { $0.address.raw.lowercased() }
        self.fromName = from?.name
        self.fromDomain = from.map { $0.address.domain.lowercased() }
        self.replyToDomain = envelope?.replyTo.first.map { $0.address.domain.lowercased() }
        self.returnPathDomain = headers?["Return-Path"].flatMap(Self.domain)
        self.recipients = ((envelope?.to ?? []) + (envelope?.cc ?? []) + (envelope?.bcc ?? []))
            .map { $0.address.raw.lowercased() }
        self.subject = envelope?.subject
        self.sentAt = envelope?.date
        self.receivedAt = summary.internalDate
        self.size = summary.size
        self.flags = summary.flags
        self.listID = headers?["List-Id"].map(Self.listID)
        self.unsubscribable = headers?["List-Unsubscribe"] != nil
        self.precedence = headers?["Precedence"]?.trimmingCharacters(in: .whitespaces).lowercased()
        self.autoSubmitted = headers?["Auto-Submitted"]?.trimmingCharacters(in: .whitespaces).lowercased()
        self.spf = Self.result("spf", in: authentication)
        self.dkim = Self.result("dkim", in: authentication)
        self.dmarc = Self.result("dmarc", in: authentication)
        self.attachments = summary.structure?.attachments ?? []
        self.labels = summary.gmail?.labels ?? []
        self.isSent = sentMailbox || self.labels.contains("\\Sent")
    }

    /// `Nieuws <nieuws.example.org>` → `nieuws.example.org`.
    package static func listID(
        _ header: String
    ) -> String {
        if let open = header.lastIndex(of: "<"), let close = header[open...].firstIndex(of: ">") {
            return String(header[header.index(after: open)..<close]).lowercased()
        }
        return header.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The domain of `<bounce@mail.example.org>`.
    package static func domain(
        _ header: String
    ) -> String? {
        let address = listID(header)
        guard let at = address.lastIndex(of: "@") else {
            return nil
        }
        let domain = address[address.index(after: at)...]
        return domain.isEmpty ? nil : String(domain)
    }

    /// The first `method=result` in `Authentication-Results`.
    package static func result(
        _ method: String,
        in authentication: String
    ) -> String? {
        guard let range = authentication.range(of: "\(method)=", options: .caseInsensitive) else {
            return nil
        }
        let value = authentication[range.upperBound...].prefix { $0.isLetter }
        return value.isEmpty ? nil : value.lowercased()
    }
}
