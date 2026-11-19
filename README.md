# Mail

Native Swift mail: compose and render MIME, send over SMTP, read and search
over IMAP, and configure accounts declaratively in Frame. No NIO, no
third-party mail stack; the wire grammars use Parsing.

## Products

| Product | What it is |
|---|---|
| `Mail` | The message model (`MailMessage`, `EmailAddress`, identities, signatures, attachments), MIME rendering and parsing (`MailRenderer`, `MIMEParser`, `ReceivedMessage`). |
| `MailConnection` | Transport shared by both protocols: TLS, STARTTLS, credentials, `MailServerConfiguration`. |
| `SMTP` | `SMTPClient`: submit over implicit TLS (465) or STARTTLS (587), `verify` to test a login. |
| `IMAP` | `IMAPClient` / `IMAPSession`: list, status, search with a typed query DSL (`IMAPSearch`), fetch summaries (optionally with chosen header fields and the `BODYSTRUCTURE` attachment tree, in batches) and messages, append. Fetching never marks mail read; selections are read-only unless selected writable, which enables `store` (flags), `copy`/`move` (with the UIDPLUS `COPYUID` mapping; `MOVE`, else copy + `UID EXPUNGE` of only those UIDs), `expunge` and `create`. Gmail extensions (search syntax, threads, labels, label changes) when the server offers them. |
| `MailIndex` | `MailIndex`: a local SQLite index per account (over the `SQLite` package) (`~/.local/share/mail/index/<account>.sqlite`) of envelopes, flags, list and authentication headers and attachments, never bodies. Incremental `sync` (UIDNEXT, flag refresh, removals, UIDVALIDITY rebuilds), correspondents from Sent, `clutter` by sender/domain/list, `select` of UIDs per mailbox for later moves. Review: `suspicious(policy)` scores received mail (payment wording from unknown vendors, strangers, rare senders, DMARC/SPF/DKIM failures, Reply-To elsewhere, lookalike domains, risky attachments) with a reason per point; durable `decisions` (trust/block a sender or domain, record/dismiss a message) survive reindexing. Server changes: `MailPlan` (move, flags/keywords, Gmail labels on targets pinned to mailbox, UIDVALIDITY, UID and Message-ID), applied by `MailPlanExecutor` (re-verifies each target, journals results with COPYUID mappings, re-syncs) and reversed with `undoPlan`. The index is a read model of the server, never edited to change mail. |
| `MailFrame` | The `Mail` Frame module and loader: accounts, providers, identities and access profiles from `.config/mail/**/*.frame` in every root: your own `~/.config/mail`, then the shared roots in `~/.config/roots.frame` (Frame's `Roots`), such as the team's synced folder. |
| `email` | The command line, over the same configuration. |

## The `email` command

```sh
email example > ~/.config/mail/accounts.frame   # a complete, valid starting point
email module                                    # install the Frame module for editor checking
email path                                      # the roots, each root's directory and the files read from it
email check                                     # validate; does every password resolve? (connects to nothing)
email probe --all                               # log in to every server; sends nothing
email accounts
email mailboxes -a work --counts
email search --unread --since 2026-11-01
email search --in 'hondenmeesters:@junk' --subject factuur
email search -a google --gmail 'has:attachment older_than:7d'
email index -a work                             # sync the local index; read-only toward the server
email clutter -a work --by domain --strangers   # biggest senders you never wrote to
email clutter -a work --by list --order bytes
email review -a work --days 30                  # suspicious mail (fake invoices, phishing) with reasons
email review -a work --block domein-registratie.example --note 'fake renewal invoice'
email review -a work --trust transip.nl         # or --record/--dismiss <uid> [-m mailbox]; --decisions lists them
email plan -a work --suspicious --move-to Review/Suspicious   # propose a server change; stored, not applied
email plan -a work --list deals.shop.example --older-than 90 --move-to Pruned
email plans -a work                             # proposed, applied, undone
email apply -a work <plan-id>                   # re-checks each message, acts, journals, re-syncs; never deletes
email undo -a work <plan-id>                    # reverses it from the journal
email bench -a work [-m INBOX.Archive]          # time the server: login, round trip, fetch per message (read-only)
email bench -a work --write                     # also APPEND/MOVE/remove one test message of its own
email read 4182 -a work -m INBOX                # headers, text, attachment list; never marks read
email read 4182 -a work --save ~/Downloads/mail # also write its attachments (never overwrites)
email read 4182 -a work --raw > message.eml     # the source as received
email draft -a work --to client@example.org -s 'Afspraak' -b '…'
email send  -a work --to client@example.org -s 'Afspraak' --body-file note.txt --attach plan.pdf
email send  -a work --to client@example.org -s 'Offerte' --html-file offerte.html --attach offerte.pdf
                                                # HTML alone gets a derived text version
```

Every command reads every root's `.config/mail`, or takes `--config <dir>` to read one directory alone, and
`--access <profile>` (limit to a named access profile). `send` shows the
message and asks before sending unless `--yes`; it saves a copy in Sent
unless the provider does that itself.

## Documentation

- [Configuration](Documentation/configuration.md): where files live, how they combine, every type.
- [Providers](Documentation/providers.md): iCloud, Gmail, Amazon SES, a self-hosted Dovecot, split read/send hosts.
- [Access](Documentation/access.md): access profiles and selectors, and how AgenticMail grants access per session.

## Build and test

```sh
sbm build   # builds and installs `email` into ~/sbm-bin
sbm test    # t_mail
```

`t_mail_live` probes real servers (iCloud, Fastmail) without credentials.
