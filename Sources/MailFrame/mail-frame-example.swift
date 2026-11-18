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

        // Gmail with an app password (myaccount.google.com/apppasswords). It files
        // sent mail itself, so no copy is saved; its search syntax, threads and
        // labels are used automatically.
        let gmail: Provider = .{
            .smtp = .{ .host = "smtp.gmail.com" },
            .imap = .{ .host = "imap.gmail.com" },
            .features = .{ .savesSentMail = true },
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

        let google: Account = .{
            .provider = gmail,
            .username = "alex@gmail.com",
            .password = .{ .env = "GMAIL_APP_PASSWORD" },
            .identities = [.{ .address = "alex@gmail.com", .name = "Alex" }],
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

        // Reading from one host and sending through another, each with its own
        // login: IMAP uses the account's username and password, while the SMTP
        // server (here SES) carries its own. Sent copies go to the IMAP host.
        let office: Account = .{
            .provider = .{
                .imap = .{ .host = "imap.mailhost.example" },
                .smtp = .{
                    .host = .{ .env = "AWS_SES_HOST" },
                    .port = .{ .env = "AWS_SES_PORT" },
                    .username = .{ .env = "AWS_SMTP_USER" },
                    .password = .{ .env = "AWS_SMTP_PASSWD" },
                },
            },
            .username = "office@practice.example",
            .password = .{ .keychain = "office" },
            .identities = [.{ .address = "office@practice.example", .name = "Practice Office" }],
            .folders = .{ .sent = "Sent" },
            .sending = .confirm,
            .about = "Read from the mailbox host, send through SES.",
        };

        // Access profiles limit what a session or command line can reach:
        // `email search --access clientDesk`, or an agent session started with
        // the profile. Accounts by binding (or by name, for other files);
        // mailboxes with a trailing * include everything below.
        let clientDesk: Access = .{
            .accounts = [work],
            .mailboxes = ["INBOX", "INBOX/Klanten/*"],
            .identities = ["info@practice.example"],
            .send = false,
            .about = "Client mail: read the client folders and draft replies as info@.",
        };
        """#
}
