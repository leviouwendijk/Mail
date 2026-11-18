# Providers

Tested and expected setups. `email probe -a <account>` logs in to each of an
account's servers and sends nothing.

## iCloud

iCloud's SMTP accepts only STARTTLS on 587; IMAP is TLS on 993. Use an
app-specific password from account.apple.com.

```frame
let icloud: Provider = .{
    .smtp = .{ .host = "smtp.mail.me.com", .security = .starttls },
    .imap = .{ .host = "imap.mail.me.com" },
};
```

## Gmail

Turn on 2-Step Verification, then create an app password at
myaccount.google.com/apppasswords. Gmail files sent mail itself, so the
provider says so and no copy is appended after sending.

```frame
let gmail: Provider = .{
    .smtp = .{ .host = "smtp.gmail.com" },
    .imap = .{ .host = "imap.gmail.com" },
    .features = .{ .savesSentMail = true },
};

let personal: Account = .{
    .provider = gmail,
    .username = "you@gmail.com",
    .password = .{ .env = "GMAIL_PERSONAL_APP_PASSWORD" },
    .identities = [.{ .address = "you@gmail.com" }],
};
```

What Gmail adds, used automatically:

- **Search syntax:** `email search --gmail 'has:attachment older_than:7d'`.
- **Threads:** results show a thread ID, and `email search --thread <id>`
  lists the whole conversation.
- **Labels:** results show their labels. Labels are mailboxes, so a selector
  like `personal:Clients` reaches one.

## Amazon SES (sending only)

SES has no IMAP, so it can send but not be searched, and there is no Sent copy
unless the account also reads from a mailbox host (below). The SMTP
credentials are SES-specific (IAM SMTP credentials, not your AWS keys) and
belong to the region in the host name; no separate region setting is needed.

```frame
let ses: Server = .{
    .host = "email-smtp.eu-north-1.amazonaws.com",
    .port = 465,
    .username = .{ .env = "AWS_SMTP_USER" },
    .password = .{ .env = "AWS_SMTP_PASSWD" },
};
```

SES only sends from verified identities (a domain or an address). In the SES
sandbox it also only sends to verified recipients.

## A self-hosted Dovecot

A Dovecot mailbox host reads over TLS on 993. If it doesn't advertise
`\Sent` and `\Drafts` (check with `email mailboxes -a <account>`), name the
folders on the account:

```frame
.folders = .{ .sent = "Sent", .drafts = "Drafts" },
```

## Reading and sending on different hosts

Read from the mailbox host with the mailbox's login, and send through SES with
SES's login. The SMTP server carries its own credentials; the account's
`username` and `password` are used by IMAP. Sent copies are appended on the
IMAP host.

```frame
let racknerd: Server = .{ .host = "mail.hondenmeesters.nl", .port = 993 };

let hondenmeestersDomain: Provider = .{ .imap = racknerd, .smtp = ses };

let levi: Account = .{
    .provider = hondenmeestersDomain,
    .username = "levi@hondenmeesters.nl",
    .password = .{ .env = "MAIL_HM_LEVI_PASSWORD" },
    .identities = [.{ .address = "levi@hondenmeesters.nl", .name = "Levi" }],
    .sending = .confirm,
};
```
