---
paths:
  - "Shared/Services/Telegram/**"
  - "Shared/Services/BackupEngine.swift"
  - "Shared/Services/BackgroundTasks.swift"
---

# Telegram and TDLib

- `FLOOD_WAIT`: wait exactly the seconds Telegram asks for, in the same job state. No shorter retries, no jitter
  below it.
- At most two uploads at once, 1.5 s apart. Don't add parallelism anywhere else (downloads, scans) without asking.
- Only touch the user's own library channel. Never send, read or delete in any other chat.
- An item is `verified` only after Telegram confirmed every part's message and each document size equals the
  uploaded stream size. Don't shortcut this for speed.
- TDLib keeps one download per file, so ranged reads of one file are serialised (`TDService.read`). Don't fan them out.
- Network and TDLib work runs off the main actor; hop back with `MainActor` only to update UI.
- Log through `AppLog`/`appLog` only. Never put file ids, chat ids, phone numbers or keys in a log string, even in
  Debug.
