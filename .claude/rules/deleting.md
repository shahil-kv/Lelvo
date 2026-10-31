---
paths:
  - "Shared/Services/FreeUpSpaceService.swift"
  - "Shared/Services/PhotoLibraryService.swift"
  - "Shared/Views/Backup/**"
  - "Shared/Views/Gallery/GalleryActions.swift"
  - "Shared/Views/Gallery/RecentlyDeletedView.swift"
  - "Packages/LelvoCore/Sources/LelvoCore/Index/CloudTrash.swift"
---

# Deleting photos

These files can remove a user's only copy of a photo.

- Phone copies are deleted only through PhotoKit (`deleteAssets`), so iOS shows its own confirmation. Never bypass it.
- Free Up Space (deleting phone copies because they are backed up) checks each item again in Telegram right before
  deleting. A `verified` row in the local index alone is not enough.
- Deleting from the cloud goes to Recently Deleted for 30 days. Permanent deletion happens only from Recently
  Deleted or when the 30 days end.
- No deletion runs without a user tap that says what will be deleted and how many. No automatic or background
  deletion.
- When unsure whether something is safe to delete, keep it and log why.
