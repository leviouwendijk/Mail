import Foundation
import Mail
import MailConnection
import MailFrame
import SMTP
import Testing

enum ConfigurationTests {
    static func directory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-config-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("mail")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Expect.equal(MailConfiguration.directory(environment: ["XDG_CONFIG_HOME": root.path]).standardizedFileURL.path, directory.standardizedFileURL.path, "XDG location")
        if case .missing = MailConfiguration.state(directory: directory) {} else {
            throw TestFlowAssertionFailure(label: "missing", message: "an empty directory is missing configuration")
        }

        func account(_ name: String) -> String {
            """
            import Mail;
            let \(name): Account = .{
                .provider = .{ .imap = .{ .host = "imap.example.org" } },
                .username = "\(name)",
                .password = .{ .env = "PW_\(name.uppercased())" },
                .identities = [.{ .address = "\(name)@example.org" }],
            };
            """
        }
        try account("work").write(to: directory.appendingPathComponent("b-work.frame"), atomically: true, encoding: .utf8)
        try account("home").write(to: directory.appendingPathComponent("a-home.frame"), atomically: true, encoding: .utf8)
        try "not mail".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let store = MailConfigurationStore(directory: directory, environment: ["PW_HOME": "h", "PW_WORK": "w"])
        guard case .loaded(let accounts) = store.state() else {
            throw TestFlowAssertionFailure(label: "loaded", message: "two files should merge")
        }
        try Expect.equal(accounts.accounts.map(\.identifier), ["home", "work"], "Files in name order")

        try account("home").write(to: directory.appendingPathComponent("c-again.frame"), atomically: true, encoding: .utf8)
        guard case .invalid(_, let message) = store.state() else {
            throw TestFlowAssertionFailure(label: "duplicate", message: "a duplicate account name should be refused")
        }
        try Expect.contains(message, "also declared in a-home.frame", "Store reloads after a new file and names the other file")
    }

    /// Files under any names form one configuration; references cross files in any order.
    static func crossFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-cross-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Read in name order: access, then accounts, then providers.
        try """
            import Mail;
            let desk: Access = .{ .accounts = [work], .mailboxes = ["INBOX"], .send = false };
            """.write(to: directory.appendingPathComponent("access.frame"), atomically: true, encoding: .utf8)
        try """
            import Mail;
            let work: Account = .{
                .provider = host,
                .username = "levi",
                .password = .{ .env = "PW" },
                .identities = [levi],
            };
            """.write(to: directory.appendingPathComponent("accounts.frame"), atomically: true, encoding: .utf8)
        try """
            import Mail;
            let host: Provider = .{ .imap = .{ .host = "imap.example.org" }, .smtp = .{ .host = "smtp.example.org" } };
            let levi: Identity = .{ .address = "levi@example.org", .name = "Levi" };
            """.write(to: directory.appendingPathComponent("providers.frame"), atomically: true, encoding: .utf8)

        guard case .loaded(let accounts) = MailConfiguration.state(directory: directory, environment: ["PW": "x"]) else {
            throw TestFlowAssertionFailure(label: "cross-file", message: "references across files should resolve: \(MailConfiguration.state(directory: directory, environment: ["PW": "x"]))")
        }
        let work = try Expect.notNil(accounts.account(named: "work"), "Account from accounts.frame")
        try Expect.equal(work.imap?.server.host, "imap.example.org", "Provider from providers.frame")
        try Expect.equal(work.defaultIdentity.address.name, "Levi", "Identity from providers.frame")
        try Expect.equal(try accounts.access(named: "desk").accounts, ["work"], "Profile in access.frame names an account binding from accounts.frame")

        // Subdirectories are read too, and reference the top level; hidden files are not.
        let practice = directory.appendingPathComponent("hondenmeesters", isDirectory: true)
        try FileManager.default.createDirectory(at: practice, withIntermediateDirectories: true)
        try """
            import Mail;
            let practiceDesk: Access = .{ .accounts = [practiceMail], .mailboxes = ["INBOX/Klanten/*"] };
            let practiceMail: Account = .{
                .provider = host,
                .username = "praktijk",
                .password = .{ .env = "PW" },
                .identities = [.{ .address = "info@hondenmeesters.nl" }],
            };
            """.write(to: practice.appendingPathComponent("access.frame"), atomically: true, encoding: .utf8)
        try "import Mail;\nlet broken: Account = 42;".write(to: practice.appendingPathComponent(".hidden.frame"), atomically: true, encoding: .utf8)

        guard case .loaded(let nested) = MailConfiguration.state(directory: directory, environment: ["PW": "x"]) else {
            throw TestFlowAssertionFailure(label: "nested", message: "subdirectory files should load: \(MailConfiguration.state(directory: directory, environment: ["PW": "x"]))")
        }
        try Expect.equal(nested.accounts.map(\.identifier), ["work", "practiceMail"], "Top level first, then the subdirectory")
        try Expect.equal(nested.account(named: "practiceMail")?.imap?.server.host, "imap.example.org", "Nested file uses a top-level provider")
        try Expect.equal(try nested.access(named: "practiceDesk").accounts, ["practiceMail"], "Nested profile")
        try Expect.equal(nested.account(named: "practiceMail")?.group, "hondenmeesters", "Group from the folder")
        try Expect.isNil(nested.account(named: "work")?.group, "Top-level files have no group")
        try Expect.equal(try MailSelector(parsing: "hondenmeesters").accounts(in: nested).map(\.identifier), ["practiceMail"], "Selector by group")

        try """
            import Mail;
            let levi: Identity = .{ .address = "other@example.org" };
            """.write(to: directory.appendingPathComponent("zz-more.frame"), atomically: true, encoding: .utf8)
        guard case .invalid(let file, let message) = MailConfiguration.state(directory: directory, environment: ["PW": "x"]) else {
            throw TestFlowAssertionFailure(label: "duplicate", message: "a name declared twice should be refused")
        }
        try Expect.true(file.hasSuffix("zz-more.frame"), "Points at the second declaration")
        try Expect.contains(message, "also declared in providers.frame", "Names the first")
    }

    static func smtpVerify() async throws {
        let transport = ScriptedTransport([
            "220 smtp.mail.me.com ESMTP",
            "250-smtp.mail.me.com",
            "250 STARTTLS",
            "220 Ready",
            "250-smtp.mail.me.com",
            "250 AUTH PLAIN LOGIN",
            "235 ok",
            "221 bye",
        ])
        let extensions = try await SMTPSession(transport: transport, startTLS: true)
            .verify(credentials: MailCredentials(username: "a", password: "b"))
        try Expect.true(extensions.contains("AUTH"), "Extensions after TLS")
        let commands = await transport.commands()
        try Expect.equal(commands.last, "QUIT", "Quits without sending")
        try Expect.false(commands.contains { $0.hasPrefix("MAIL FROM") }, "Nothing sent")
    }
}
