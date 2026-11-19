# Access

Two mechanisms limit what a session can reach. **Access profiles** are
declared in the configuration and set a ceiling. **Selectors** name accounts
and mailboxes; AgenticMail grants them per session, on request.

## Access profiles

```frame
let clientDesk: Access = .{
    .accounts = [work, "office"],         // by binding, or by name for other files; all when absent
    .mailboxes = ["INBOX", "INBOX/Klanten/*"],  // a trailing * includes everything below; all when absent
    .identities = ["info@practice.example"],    // who it may draft or send as; all when absent
    .send = false,                        // drafts only
    .draft = true,                        // false: read only
    .about = "Client mail: read client folders, draft replies as info@.",
};
```

A profile only narrows: it never loosens an account's `sending` policy.
Limiting `mailboxes` also refuses Gmail search syntax and thread search,
because those reach across labels.

On the command line, `--access clientDesk` applies a profile to any `email`
command. `email check` lists every profile.

## Selectors

A selector is a target, optionally followed by a mailbox part:

| Selector | Picks |
|---|---|
| `levi` | Every mailbox of the account `levi`. |
| `hondenmeesters` | Every account in the group `hondenmeesters`. |
| `*` | Every account. |
| `levi:INBOX` | One mailbox. |
| `levi:INBOX/Klanten/*` | A mailbox and everything below it. |
| `hondenmeesters:@junk` | The Junk folder of every account in the group, whatever each server calls it. |

The roles are `@inbox`, `@sent`, `@drafts`, `@junk`, `@trash`, `@archive`,
`@all` and `@flagged`. A role is found from the server's SPECIAL-USE
attributes, or from the account's `folders` when the server has none.

On the command line, `email search --in <selector>` (repeatable) searches
across everything the selectors pick:

```sh
email search --in 'hondenmeesters:@junk' --since 2026-11-01
email search --in leads --in 'levi:INBOX/Klanten/*' --unread
```

## Agents (AgenticMail)

The `Email` domain in AgenticDomains reads this same configuration. Its rule
is that an agent sees metadata by default and content only by grant:

- **Metadata by default.** A session starts with no grants. `mail_accounts`
  shows accounts, groups, `about` texts and what is granted, never mail.
- **Grants on request.** `mail_request_access` asks the owner for selectors
  (or a profile) at `read` or `draft` level, with a reason. It is always
  reviewed, and grants last until the session ends.
- **Read only what is granted.** `mail_mailboxes`, `mail_search` and
  `mail_read` refuse anything outside the grants, before connecting.
- **Attachments as files.** `mail_save_attachment` needs the same read grant
  and writes to `mail/<account>/<mailbox>-<uid>/` under the exports directory
  of Agentic's `settings.frame` (`exports.directory`; by default
  `.agentic/artifacts/exports` in the workspace). It never overwrites.
- **Writing.** `mail_draft` needs a `draft` grant. `mail_send` needs no grant:
  the owner approves each message. The account's `sending` policy decides the rest:
  - `drafts`: refused;
  - `confirm`: the owner approves each message;
  - `allowed`: the owner approves each message, unless the session holds a
    `draft` grant on the account, in which case it sends without asking.

  A reply (`reply_to_uid`) still needs read access to the original's mailbox.
- **Profiles as a ceiling.** A host can start a session limited to an access
  profile (`Email.Scope`); requests beyond it are refused.

The `email` command is not gated this way: it runs as you, with `--access` as
an optional limit.
