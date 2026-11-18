# Configuration

Mail accounts are declared in Frame files. The `email` command, AgenticMail
and any other consumer of `MailFrame` read the same files, so an account is
configured once.

## Where the files live

Every `*.frame` file under `$XDG_CONFIG_HOME/mail`, or `~/.config/mail`, at any
depth and under any name. Hidden files are skipped and symbolic links are not
followed. `email path` prints the directory and the files it reads.

```
~/.config/mail/
├── providers.frame
├── hondenmeesters/
│   ├── accounts.frame
│   └── access.frame
└── leviouwendijk/
    ├── accounts.frame
    └── access.frame
```

How the files combine:

- **One configuration.** Each file starts with `import Mail;`. All files
  together form one configuration: a binding may reference one declared in
  another file, in any order.
- **Unique names.** A name declared in two files is an error naming both.
- **Every error at once.** Each file is checked with the others' bindings in
  scope, and every failing file is reported, not just the first.
- **Default account.** Files are read in relative-path order; the first account
  in the first file that declares one is the default.
- **Groups from folders.** An account in a file under a top-level folder
  belongs to that folder's group (`hondenmeesters`, `leviouwendijk` above),
  unless it sets `.group` itself. Groups let one selector reach several
  accounts; see [Access](access.md).

Start from a complete, valid example and check as you go:

```sh
email example > ~/.config/mail/accounts.frame
email module    # editor completion and checking for .frame files
email check     # validates, and says per server whether its password resolves
```

## Values from the environment

`host`, `port` and `username` take a literal or an environment variable:

```frame
.host = "email-smtp.eu-north-1.amazonaws.com",
.port = 465,
.username = .{ .env = "AWS_SMTP_USER" },
```

Variables are read when the configuration loads. An unset one does not fail
the configuration: it leaves out only the server that needs it, and
`email check` shows that server as `UNAVAILABLE` with the variable's name. An
account that sends through SES with SES's own login can therefore send before
its mailbox login is set. An empty written value (`.host = ""`) is still an
error. Passwords are never literals: a `Secret` names where the password is
kept.

A convention that keeps the variables findable: the username is usually
just the address, written literally, and the password is `MAIL_PASSWORD_<ID>`,
with `<ID>` the mailbox and a short domain tag, as in `MAIL_PASSWORD_LEVI_HM`.
A Gmail app password goes there too. When a username must stay out of the
file, use `MAIL_USER_<ID>`.

```frame
.password = .{ .env = "MAIL_WORK_PASSWORD" },
.password = .{ .keychain = "work" },   // account name under the `mail` keychain service
```

A process sees only its own environment: an app launched from the Dock does
not inherit shell exports. Give it the same variables, or use the keychain.

## Types

### Server

One mail server.

| Field | |
|---|---|
| `host` | Required. Literal or `.{ .env }`. |
| `port` | Literal or `.{ .env }`. Default: SMTP 465 (587 with `starttls`), IMAP 993 (143 with `starttls`). |
| `security` | `.tls` (the default: TLS from the first byte), `.starttls` (plain, upgraded before login; refused if the server doesn't offer it), `.plaintext` (local relays only; never sends a password). |
| `username`, `password` | This server's own login, when it differs from the account's. |

A server can be bound once and referenced from providers:

```frame
let racknerd: Server = .{ .host = "mail.hondenmeesters.nl", .port = 993 };
```

### Provider

A mail host's servers, shared by its accounts.

| Field | |
|---|---|
| `smtp` | Where mail is submitted. Absent: the account cannot send. |
| `imap` | Where mail is read. Absent: the account cannot be searched. |
| `features` | `.{ .savesSentMail = true }` when the provider files sent mail itself (Gmail); then no copy is appended after sending. |

Gmail's search syntax, thread IDs and labels need no setting: they follow from
the server advertising `X-GM-EXT-1`.

### Account

A mailbox, identified by its binding name.

| Field | |
|---|---|
| `provider` | Required. A bound provider or an inline one. |
| `username`, `password` | The login, used by every server that sets none of its own. |
| `identities` | Required. Addresses the account sends as; the first is the default. |
| `folders` | Folder names by role (`sent`, `drafts`, `archive`, `trash`, `junk`), only where the server doesn't advertise SPECIAL-USE. |
| `sending` | What an agent may do with outgoing mail: `.drafts` (the default: only draft), `.confirm` (send after the owner confirms each message), `.allowed` (send without asking). The `email` command always confirms unless `--yes`. |
| `group` | Overrides the group taken from the folder. |
| `about` | What the account is for, in your words; shown to agents. |

### Identity and Signature

```frame
let practice: Identity = .{
    .address = "alex@practice.example",
    .name = "Alex Example",
    .replyTo = "office@practice.example",
    .signature = .{ .text = "Alex Example\nPractice Example" },  // or .html; either is derived from the other
};
```

### Access

A named access profile; see [Access](access.md).

## How a login is resolved

For each server: its own `username` and `password` when set, otherwise the
account's. This is what lets one account read from a mailbox host with the
mailbox login while sending through Amazon SES with SES credentials; see
[Providers](providers.md#reading-and-sending-on-different-hosts).

`email check` prints, per server, which login it uses and whether the
password resolves, or which variable or keychain item is missing.
