import Foundation
import IMAP
import Mail
import MailFrame
import Testing

enum SelectorTests {
    static func parsing() throws {
        try Expect.equal(try MailSelector(parsing: "levi").description, "levi", "Account")
        try Expect.equal(try MailSelector(parsing: " hondenmeesters : @Junk ").description, "hondenmeesters:@junk", "Group and role")
        try Expect.equal(try MailSelector(parsing: "*:@sent").target, .all, "All accounts")
        try Expect.equal(try MailSelector(parsing: "levi:INBOX/Klanten/*").mailboxes, .pattern("INBOX/Klanten/*"), "Pattern")
        try Expect.equal(try MailSelector(parsing: "levi:@inbox").mailboxes, .role(.inbox), "Inbox role")
        try Expect.throwsError("Unknown role") { _ = try MailSelector(parsing: "levi:@spam") }
        try Expect.throwsError("Empty") { _ = try MailSelector(parsing: " ") }
    }

    static func matching() throws {
        let accounts = try MailAccounts(source: MailFrame.example, environment: FrameTests.environment)
        let work = try Expect.notNil(accounts.account(named: "work"), "Work")
        let listed = [
            IMAPMailbox(name: "INBOX", delimiter: "/", attributes: []),
            IMAPMailbox(name: "Spam", delimiter: "/", attributes: ["\\Junk"]),
            IMAPMailbox(name: "Archive", delimiter: "/", attributes: []),
            IMAPMailbox(name: "Folders", delimiter: "/", attributes: ["\\Noselect"]),
        ]
        try Expect.equal(MailboxRole.of("Spam", account: work, listed: listed), .special(.junk), "Role from SPECIAL-USE")
        try Expect.equal(MailboxRole.of("Archive", account: work, listed: listed), .special(.archive), "Role from the file's folders override")
        try Expect.equal(MailboxRole.of("inbox", account: work, listed: listed), .inbox, "INBOX by name")

        let junk = try MailSelector(parsing: "work:@junk")
        try Expect.equal(junk.mailboxes(of: work, listed: listed).map(\.name), ["Spam"], "Role picks the server's name")
        try Expect.equal(try MailSelector(parsing: "work").mailboxes(of: work, listed: listed).map(\.name), ["INBOX"], "No mailbox part searches INBOX")
        try Expect.equal(try MailSelector(parsing: "work:*").mailboxes(of: work, listed: listed).map(\.name), ["INBOX", "Spam", "Archive"], "* skips unselectable folders")

        try Expect.equal(try MailSelector(parsing: "*").accounts(in: accounts).count, accounts.accounts.count, "All accounts")
        try Expect.throwsError("Unknown account or group") { _ = try MailSelector(parsing: "nobody").accounts(in: accounts) }
    }
}
