import Foundation
import IMAP
import Mail
import MailFrame
import Milieu
import Testing

enum FrameTests {
    /// What the example's `.{ .env = … }` settings read.
    static let environment = [
        "MAIL_WORK_PASSWORD": "app-password",
        "AWS_SES_HOST": "email-smtp.eu-north-1.amazonaws.com",
        "AWS_SES_PORT": "465",
        "AWS_SMTP_USER": "AKIAEXAMPLE",
        "AWS_SMTP_PASSWD": "ses-secret",
    ]

    static func example() async throws {
        let accounts = try MailAccounts(
            source: MailFrame.example,
            environment: environment
        )

        try Expect.equal(accounts.accounts.map(\.identifier), ["work", "personal", "transactional", "office"], "Accounts in order")
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
        let accounts = try MailAccounts(source: MailFrame.example, environment: environment)
        let identity = try Expect.notNil(accounts.defaultAccount?.defaultIdentity, "Identity")
        let message = identity.message(
            to: [try NamedAddress("jan@example.org")],
            subject: "Hoi",
            body: .text("Tot morgen.")
        )
        try Expect.equal(message.body, .text("Tot morgen.\n\n-- \nAlex Example\nPractice Example"), "Signed text")
    }

    static func environmentSettings() async throws {
        let accounts = try MailAccounts(source: MailFrame.example, environment: environment)
        let ses = try Expect.notNil(accounts.account(named: "transactional"), "SES account")
        try Expect.isNil(ses.imap, "Send-only")
        try Expect.equal(ses.smtp?.server.host, "email-smtp.eu-north-1.amazonaws.com", "Host from env")
        try Expect.equal(ses.smtp?.server.port, 465, "Port from env")
        try Expect.equal(ses.smtp?.server.authentication?.username, "AKIAEXAMPLE", "Username from env")
        let password = try await accounts.credentials.resolve(ses.smtp!.server.authentication!.password).utf8()
        try Expect.equal(password, "ses-secret", "Password from env at connect time")

        let office = try Expect.notNil(accounts.account(named: "office"), "Split account")
        try Expect.equal(office.imap?.server.host, "imap.mailhost.example", "Reads from the mailbox host")
        try Expect.equal(office.imap?.server.authentication?.username, "office@practice.example", "IMAP uses the account login")
        try Expect.equal(office.smtp?.server.host, "email-smtp.eu-north-1.amazonaws.com", "Sends through SES")
        try Expect.equal(office.smtp?.server.authentication?.username, "AKIAEXAMPLE", "SMTP uses its own login")
        try Expect.equal(accounts.source(of: office.imap!.server.authentication!.password), "keychain item office (service mail)", "IMAP password from the keychain")
        try Expect.equal(office.folders[.sent], "Sent", "Sent copies on the IMAP host")

        var unset = environment
        unset["AWS_SES_HOST"] = nil
        do {
            _ = try MailAccounts(source: MailFrame.example, environment: unset)
            throw TestFlowAssertionFailure(label: "unset", message: "an unset host variable should be refused")
        } catch let failure as MailAccounts.Failure {
            try Expect.contains(failure.localizedDescription, "AWS_SES_HOST is unset", "Names the variable")
        }

        var badPort = environment
        badPort["AWS_SES_PORT"] = "smtp"
        try Expect.throwsError("Port variable must be a number") {
            _ = try MailAccounts(source: MailFrame.example, environment: badPort)
        }
    }

    /// Reading from a mailbox host and sending through SES, with different logins.
    static func splitServers() async throws {
        let accounts = try MailAccounts(source: """
            import Mail;
            let mail: Account = .{
                .provider = .{
                    .imap = .{ .host = "imap.mailhost.example" },
                    .smtp = .{
                        .host = .{ .env = "AWS_SES_HOST" },
                        .username = .{ .env = "AWS_SMTP_USER" },
                        .password = .{ .env = "AWS_SMTP_PASSWD" },
                    },
                },
                .username = "levi@hondenmeesters.nl",
                .password = .{ .env = "MAILHOST_PASSWORD" },
                .identities = [.{ .address = "levi@hondenmeesters.nl" }],
            };
            """, environment: environment.merging(["MAILHOST_PASSWORD": "imap-secret"]) { $1 })

        let account = try Expect.notNil(accounts.defaultAccount, "Account")
        let imap = try Expect.notNil(account.imap?.server.authentication, "IMAP login")
        let smtp = try Expect.notNil(account.smtp?.server.authentication, "SMTP login")
        try Expect.equal(imap.username, "levi@hondenmeesters.nl", "IMAP uses the account login")
        try Expect.equal(smtp.username, "AKIAEXAMPLE", "SMTP uses its own login")
        try Expect.equal(try await accounts.credentials.resolve(imap.password).utf8(), "imap-secret", "IMAP password")
        try Expect.equal(try await accounts.credentials.resolve(smtp.password).utf8(), "ses-secret", "SMTP password")

        do {
            _ = try MailAccounts(source: """
                import Mail;
                let a: Account = .{
                    .provider = .{ .smtp = .{ .host = "smtp.example.org", .username = "u" } },
                    .identities = [.{ .address = "a@example.org" }],
                };
                """)
            throw TestFlowAssertionFailure(label: "no-password", message: "a server without any password should be refused")
        } catch let failure as MailAccounts.Failure {
            try Expect.contains(failure.localizedDescription, "a.provider.smtp.password", "Names the server")
        }
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
