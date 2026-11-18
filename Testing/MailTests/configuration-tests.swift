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
        try Expect.contains(message, "more than one file", "Store reloads after a new file")
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
