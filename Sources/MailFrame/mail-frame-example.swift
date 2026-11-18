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

        // A send-only provider read from the environment, such as Amazon SES:
        // host, port and username may be `.{ .env = "…" }` like the password.
        // A server may also carry its own username and password, so one
        // account can read from a mailbox host and send through SES.
        let ses: Provider = .{
            .smtp = .{
                .host = .{ .env = "AWS_SES_HOST" },
                .port = .{ .env = "AWS_SES_PORT" },
            },
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

        // SES sends only as verified identities; it has no IMAP, so no Sent copy.
        let transactional: Account = .{
            .provider = ses,
            .username = .{ .env = "AWS_SMTP_USER" },
            .password = .{ .env = "AWS_SMTP_PASSWD" },
            .identities = [.{ .address = "noreply@practice.example", .name = "Practice Example" }],
            .sending = .allowed,
            .about = "Transactional mail through Amazon SES.",
        };
        """#
}
