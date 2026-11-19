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
| `MailIndex` | `MailIndex`: a local SQLite index per account (`~/.local/share/mail/index/<account>.sqlite`) of envelopes, flags, list and authentication headers and attachments, never bodies. Incremental `sync` (UIDNEXT, flag refresh, removals, UIDVALIDITY rebuilds), correspondents from Sent, `clutter` by sender/domain/list, `select` of UIDs per mailbox for later moves. |
| `MailFrame` | The `Mail` Frame module and loader: accounts, providers, identities and access profiles from `~/.config/mail/**/*.frame`. |
| `email` | The command line, over the same configuration. |

## The `email` command

```sh
email example > ~/.config/mail/accounts.frame   # a complete, valid starting point
email module                                    # install the Frame module for editor checking
email path                                      # the directory and the files read from it
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
email read 4182 -a work -m INBOX                # headers, text, attachment list; never marks read
email read 4182 -a work --save ~/Downloads/mail # also write its attachments (never overwrites)
email read 4182 -a work --raw > message.eml     # the source as received
email draft -a work --to client@example.org -s 'Afspraak' -b '…'
email send  -a work --to client@example.org -s 'Afspraak' --body-file note.txt --attach plan.pdf
email send  -a work --to client@example.org -s 'Offerte' --html-file offerte.html --attach offerte.pdf
                                                # HTML alone gets a derived text version
```

Every command takes `--config <dir>` (instead of `~/.config/mail`) and
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
