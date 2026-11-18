import Foundation
import IMAP
import Mail
import MailFrame
import Milieu
import Testing

enum FrameTests {
    static func example() async throws {
        let accounts = try MailAccounts(
            source: MailFrame.example,
            environment: ["MAIL_WORK_PASSWORD": "app-password"]
        )

        try Expect.equal(accounts.accounts.map(\.identifier), ["work", "personal"], "Accounts in order")
        let work = try Expect.notNil(accounts.defaultAccount, "Default account")
        try Expect.equal(work.identifier, "work", "First is default")
        try Expect.equal(work.identities.map(\.address.address.raw), ["alex@practice.example", "info@practice.example"], "Identities")
        try Expect.equal(work.sending, .confirm, "Sending policy")
        try Expect.equal(work.folders[.archive], "Archive", "Folder override")
        try Expect.equal(work.smtp?.server.port, 465, "SMTP default port")
        try Expect.equal(work.smtp?.clientName, "practice.example", "EHLO name from identity")
        try Expect.equal(work.imap?.server.port, 993, "IMAP default port")
        try Expect.equal(accounts.account(named: "personal")?.sending, .drafts, "Drafts by default")

        let reference = try Expect.notNil(work.imap?.server.authentication?.password, "Password reference")
        let password = try await accounts.credentials.resolve(reference).utf8()
        try Expect.equal(password, "app-password", "Env symbol resolved")

        let sender = try EmailAddress("info@practice.example")
        try Expect.equal(accounts.account(sendingAs: sender)?.identifier, "work", "Account by identity")
    }

    static func signature() throws {
        let accounts = try MailAccounts(source: MailFrame.example, environment: [:])
        let identity = try Expect.notNil(accounts.defaultAccount?.defaultIdentity, "Identity")
        let message = identity.message(
            to: [try NamedAddress("jan@example.org")],
            subject: "Hoi",
            body: .text("Tot morgen.")
        )
        try Expect.equal(message.body, .text("Tot morgen.\n\n-- \nAlex Example\nPractice Example"), "Signed text")
    }

    static func invalid() throws {
        try Expect.throwsError("Both env and keychain") {
            _ = try MailAccounts(source: """
                import Mail;
                let a: Account = .{
                    .provider = .{ .imap = .{ .host = "imap.example.org" } },
                    .username = "a",
                    .password = .{ .env = "A", .keychain = "a" },
                    .identities = [.{ .address = "a@example.org" }],
                };
                """)
        }
        try Expect.throwsError("Invalid identity address") {
            _ = try MailAccounts(source: """
                import Mail;
                let a: Account = .{
                    .provider = .{ .imap = .{ .host = "imap.example.org" } },
                    .username = "a",
                    .password = .{ .env = "A" },
                    .identities = [.{ .address = "not an address" }],
                };
                """)
        }
        try Expect.throwsError("Port out of range") {
            _ = try MailAccounts(source: """
                import Mail;
                let a: Account = .{
                    .provider = .{ .smtp = .{ .host = "smtp.example.org", .port = 70000 } },
                    .username = "a",
                    .password = .{ .env = "A" },
                    .identities = [.{ .address = "a@example.org" }],
                };
                """)
        }
    }
}
