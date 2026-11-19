# Configuration

Mail accounts are declared in Frame files. The `email` command, AgenticMail
and any other consumer of `MailFrame` read the same files, so an account is
configured once.

## Where the files live

Every `*.frame` file under `.config/mail/` of every **root**, at any depth and
under any name. Hidden files are skipped and symbolic links are not followed.

- **Your own root** is your home directory: `~/.config/mail` (or
  `$XDG_CONFIG_HOME/mail`). Personal mailboxes and aliases go here.
- **Shared roots** are declared in `~/.config/roots.frame` (Frame's `Roots`
  library), such as a team folder in iCloud. Each holds the same tree as your
  home, so its mail configuration is `<root>/.config/mail/`. Shared mailboxes,
  providers and team access profiles go there, for everyone at once.

```
// ~/.config/roots.frame
import Roots;
let hondenmeesters: Root = .{ .path = "~/Library/Mobile Documents/com~apple~CloudDocs/Shared Files/Hondenmeesters", .writable = true };
```

```
~/.config/mail/                         your own
├── providers.frame                     leviouwendijkDomain
├── hondenmeesters/accounts.frame       levi@ (joins the hondenmeesters group)
└── leviouwendijk/
    ├── accounts.frame
    └── access.frame

<Hondenmeesters>/.config/mail/          shared root
├── providers.frame                     racknerd, ses, gmail, hondenmeestersDomain
└── hondenmeesters/
    ├── accounts.frame                  support@, contact@, betalingen@, …
    └── access.frame                    team profiles
```

`email path` prints the roots file, each root's directory and the files it
reads, with any problem: a declared root that is not there, a file iCloud has
not downloaded yet, or a sync conflict copy. `--config <dir>` reads that one
directory alone instead.

How the files combine:

- **One configuration.** Each file starts with `import Mail;`. All files of all
  roots together form one configuration: a binding may reference one declared
  in another file or another root, in any order.
- **Unique names.** A name declared in two files, in the same root or not, is
  an error naming both.
- **Every error at once.** Each file is checked with the others' bindings in
  scope, and every failing file is reported, not just the first.
- **Default account.** Your own root is read first, then each shared root,
  each in relative-path order; the first account is the default, so it is
  always one of your own when you have any.
- **Groups from folders.** An account in a file under a top-level folder
  belongs to that folder's group (`hondenmeesters`, `leviouwendijk` above) in
  whichever root; an account in a shared root's top-level file belongs to the
  root's group. `.group` overrides both. Groups let one selector reach several
  accounts; see [Access](access.md).
- **No secrets in any root.** Passwords are named (`.env`, keychain) and set
  on each machine; a synced folder never holds one.
- **Caches stay local.** The index (`~/.local/share/mail/index`) is per
  machine and never belongs in a root.
- **Synced folders.** A file iCloud has not downloaded, or a conflict copy
  (`accounts 2.frame`), stops loading with a message rather than silently
  dropping or doubling accounts.

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
