# Security

Memvo holds people's whole photo libraries and a session for their Telegram account, so security reports get
priority over everything else.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub:
[Report a vulnerability](https://github.com/shahil-kv/Memvo/security/advisories/new) (Security tab → Report a
vulnerability).

Include what you found, how to reproduce it, which app and version, and what an attacker could do with it. A short
proof of concept helps. Please don't access other people's data or Telegram accounts while testing.

What happens next:

- An acknowledgement within **3 days**.
- An assessment and a plan within **10 days**.
- A fix released as soon as possible, then a published advisory crediting you (unless you'd rather stay anonymous).

## Supported versions

Only the latest release of each app gets security fixes. Please update before reporting.

## In scope

- The iOS and Mac apps in this repository and their release builds.
- The storage format and end-to-end encryption ([docs/CLOUD_FORMAT.md](docs/CLOUD_FORMAT.md)): anything that weakens
  it, leaks plaintext, filenames or keys, or lets a modified channel trick the app.
- Secrets leaking from the Keychain, logs, caches, backups or crash output.
- The CI workflows and release pipeline.

## Out of scope

- Telegram's servers, apps and protocol: report those through [Telegram's bug bounty program](https://core.telegram.org/bug-bounty).
- Attacks that need a jailbroken device or physical access to an unlocked device.
- Apple platform bugs: report those to [Apple](https://security.apple.com).
