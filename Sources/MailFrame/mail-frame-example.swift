public extension MailFrame {
    /// A complete `mail.frame` with made-up accounts. The tests read it as a
    /// configuration, so it stays valid.
    static let example = #"""
        import Mail;

        // Servers, bound once and shared by accounts on the same host.
        let fastmail: Provider = .{
            .smtp = .{ .host = "smtp.fastmail.com" },
            .imap = .{ .host = "imap.fastmail.com" },
        };

        // iCloud submits only on 587 with STARTTLS; it reads over TLS on 993.
        // Use an app-specific password from account.apple.com.
        let icloud: Provider = .{
            .smtp = .{ .host = "smtp.mail.me.com", .security = .starttls },
            .imap = .{ .host = "imap.mail.me.com" },
        };

        let practice: Identity = .{
            .address = "alex@practice.example",
            .name = "Alex Example",
            .signature = .{ .text = "Alex Example\nPractice Example" },
        };

        // Accounts, by binding name; the first is the default.
        let work: Account = .{
            .provider = fastmail,
            .username = "alex@practice.example",
            // Never the password itself: the variable or keychain item holding it.
            .password = .{ .env = "MAIL_WORK_PASSWORD" },
            .identities = [
                practice,
                .{ .address = "info@practice.example", .name = "Practice Example" },
            ],
            .folders = .{ .archive = "Archive" },
            .sending = .confirm,
            .about = "Client mail for the practice.",
        };

        let personal: Account = .{
            .provider = icloud,
            .username = "alex@icloud.com",
            .password = .{ .keychain = "personal" },
            .identities = [.{ .address = "alex@icloud.com", .name = "Alex" }],
        };
        """#
}
