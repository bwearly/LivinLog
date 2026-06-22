# Livin Log reliability architecture report

## Root causes found

1. **Store configuration failure was being treated as a crash-only condition.** The Core Data stack uses two CloudKit-backed SQLite stores (`LivinLog.sqlite` private and `LivinLog-shared.sqlite` shared). Both stores must continue to use the model default configuration. If an older/dev build wrote either store with a named configuration, Core Data can report: “The model configuration used to open the store is incompatible with the one that was used to create the store.” The app already had migration options via raw store options, but it did not explicitly pin the default configuration or log store metadata on failure.
2. **Shared-household membership was vulnerable to cross-store identity relationships.** The app had a single current `AppUser` object, then attempted to use it for memberships and book ownership even when the household lived in the shared store. Core Data relationships cannot safely span persistent stores. That makes member claiming and book saves fail or silently roll back in CloudKit share flows.
3. **UserDefaults selection was too trusted for durable ownership.** `SelectionStore` caches object URI selections. That is acceptable as a cache, but not as durable identity. The launch path now refuses to use cached member selection to auto-claim a shared household and checks claimed durable user IDs before any private-store legacy auto-migration.
4. **Book creation failed silently.** `AddEditBookView` returned early or used `try? context.save()`, hiding authorization and cross-store persistence errors from users.
5. **Invite entry was link-only.** Joining required a full iCloud share URL. Manual entry now accepts either the full iCloud share link or the share code/token portion of that link.

## Architecture implemented

- Durable actor identity remains Sign in with Apple (`apple:<providerSubject>`), persisted as `AppUser` and cached in Keychain only as a session hint.
- `AppUser` objects are now store-scoped when writing relationships. The same durable provider subject can exist in private and shared stores so `HouseholdMembership`, `HouseholdMember`, and `BookEntry` relationships remain inside one persistent store.
- `HouseholdMembership` is the source of acting authority. It carries durable scalar IDs in addition to relationships so launch and authorization do not depend solely on object URI caches.
- `HouseholdMember.claimedByAppUserId` records the durable owner of a profile. Legacy/imported members may remain nil until explicitly claimed.
- Book writes require a resolved current `AppUser`, `Household`, and claimed/authorized `HouseholdMember`; writes are denied with visible errors when the actor cannot be resolved or attempts to write for another member.
- Pending invite URLs are stored only until accepted or explicitly cleared. Resume attempts are guarded so the same invalid invite cannot continuously refetch or re-present an error loop in one app session.

## Data model changes

- `AppUser.lastSeenAt`
- `Household.createdByAppUserId`
- `HouseholdMember.claimedByAppUserId`
- `HouseholdMembership.appUserId`, `householdId`, `householdMemberId`, `joinedAt`
- `BookEntry.householdId`, `ownerMemberId`, `ownerAppUserId`
- `BookEntry.coverID`, `isbn`, `firstPublishYear` for reliable OpenLibrary cover/result persistence
- New `Invite` entity for future first-class invite tracking (`inviteCode`, `token`, `householdId`, creator, dates, max uses, status, relationship to household)

All new fields are optional to preserve lightweight migration compatibility with already-shipped stores.

## CloudKit Production schema checklist

TestFlight and App Store builds use the **Production** CloudKit schema. Before uploading a TestFlight build, deploy the Development schema containing these Core Data entities, attributes, and relationships to Production:

| Entity | Attributes | Relationships |
| --- | --- | --- |
| `Household` | `createdByAppUserId`, `createdAt`, `id`, `name` | `calendarEvents`, `feedbacks`, `members`, `movies`, `puzzles`, `children`, `quotes`, `tvshows`, `viewings`, `memberships`, `bookEntries`, `invites` |
| `HouseholdMember` | `claimedByAppUserId`, `createdAt`, `displayName`, `id` | `feedbacks`, `household`, `memberships`, `bookEntries` |
| `LLCalendarEvent` | `createdAt`, `day`, `id`, `month`, `name`, `notificationsEnabledForEvent`, `tag`, `updatedAt`, `year` | `household` |
| `LLChild` | `birthday`, `createdAt`, `id`, `name`, `updatedAt` | `household`, `quotes` |
| `LLPuzzle` | `brand`, `completedAt`, `createdAt`, `id`, `name`, `notes`, `photoData`, `pieceCount`, `updatedAt` | `household` |
| `LLQuote` | `ageInMonthsAtSaidAt`, `contextText`, `createdAt`, `householdId`, `id`, `saidAt`, `speakerName`, `text`, `updatedAt` | `child`, `household` |
| `Movie` | `createdAt`, `genre`, `householdID`, `id`, `mpaaRating`, `notes`, `posterURL`, `title`, `year` | `feedbacks`, `household`, `viewing` |
| `MovieFeedback` | `id`, `notes`, `rating`, `slept`, `updatedAt` | `household`, `member`, `movie` |
| `TVShow` | `createdAt`, `householdID`, `id`, `notes`, `posterURL`, `ratingText`, `rewatch`, `seasons`, `title`, `year` | `household` |
| `Viewing` | `id`, `isRewatch`, `notes`, `watchedOn` | `household`, `movie` |
| `AppUser` | `lastSeenAt`, `id`, `authProvider`, `providerSubject`, `displayName`, `createdAt` | `memberships`, `bookEntries` |
| `HouseholdMembership` | `joinedAt`, `householdMemberId`, `householdId`, `appUserId`, `id`, `role`, `status`, `createdAt` | `household`, `memberProfile`, `appUser` |
| `BookEntry` | `ownerAppUserId`, `ownerMemberId`, `householdId`, `id`, `title`, `author`, `rating`, `notes`, `spiceLevel`, `bookLength`, `createdAt`, `finishedAt`, `coverURL`, `coverID`, `isbn`, `firstPublishYear` | `household`, `ownerMember`, `ownerAppUser` |
| `Invite` | `id`, `inviteCode`, `token`, `createdByAppUserId`, `householdId`, `status`, `createdAt`, `expiresAt`, `maxUses` | `household` |

## Migration and recovery implications

- Lightweight migration is enabled explicitly on both persistent store descriptions.
- The app does **not** silently delete production stores. On load failure, it logs the store URL, configuration, metadata, and Core Data error. In DEBUG only, logs explain that simulator/dev stores can be manually removed and the recovery UI exposes a development reset action.
- The production recovery screen does not expose destructive reset controls. Its user-visible diagnostics are limited to the store file name, configuration, Core Data error domain/code, and localized system message.
- Existing single-member private households can be auto-migrated to a membership only when the member is unclaimed or already claimed by the same durable user.
- Shared households are never auto-claimed from `UserDefaults`; invitees must create or explicitly claim a profile.

## CloudKit sharing production schema repair checklist

Use this checklist when TestFlight sharing reports a production-schema error for a Core Data/CloudKit internal sharing field such as `CD_moveReceipt`. Do **not** add that field to the Core Data model and do **not** manually edit CloudKit records or shares.

1. Run the DEBUG-only schema initializer against the Development CloudKit container from Settings → Developer Diagnostics → Initialize Development CloudKit Schema.
2. Confirm CloudKit Dashboard shows the generated Development schema changes, including any Core Data/CloudKit internal sharing fields.
3. Deploy schema changes from Development to Production in CloudKit Dashboard.
4. Archive a fresh Release/TestFlight build after the Production schema deployment is complete.
5. Delete the old TestFlight app from the test device so stale local stores do not mask the result.
6. Install the fresh TestFlight build.
7. Create and share a household.
8. Confirm the `CD_moveReceipt` production-schema error is gone.

## Before TestFlight upload checklist

1. Confirm the Release build configuration does not define `DEBUG`, and verify the DEBUG-only store reset UI is absent in an archive/Release build.
2. Confirm `StoreRecoveryView.swift` and `PendingInviteStore.swift` are part of the app target via the Xcode file-system-synchronized `Livin Log` target folder.
3. Deploy the exact CloudKit schema listed above from Development to Production, including the optional BookEntry OpenLibrary metadata fields.
4. Archive with the corrected `Livin Log/LivinLog.entitlements` path and validate signing capabilities for iCloud/CloudKit.
5. Install the archived build on a device or TestFlight internal tester before external release and complete the ordered manual checklist below.

## Final ordered manual testing checklist

1. App Store build update to new TestFlight build.
2. Fresh install owner flow.
3. Delete/reinstall same Apple ID recovery.
4. New phone recovery.
5. Owner invite link generation.
6. Signed-out invite link resume.
7. Signed-out manual invite resume.
8. Invitee joins with second Apple ID.
9. Owner and invitee book creation.
10. Cross-member book edit blocked.
11. Invalid invite clear.
12. Store recovery screen test.

## TestFlight/App Store style checklist

1. Fresh install: sign in with Apple, create household, verify one owner membership and claimed member.
2. App update from old build: open existing store, verify lightweight migration, no model configuration crash, and no silent store deletion.
3. Delete/reinstall on same Apple ID: sign in with Apple again, wait for CloudKit import, verify memberships recover.
4. New phone/simulator signed into same Apple/iCloud account: sign in with Apple, wait for CloudKit import, verify memberships recover.
5. Owner creates household: verify `createdByAppUserId`, owner `HouseholdMembership`, and `claimedByAppUserId` are set.
6. Invitee joins with link: accept iCloud share, enter display name, verify member and membership are in the shared store.
7. Invitee joins with manual code: paste only the code/token segment from the iCloud link, accept, enter display name, verify routing as that member.
8. Owner adds book: verify book has household/member/app-user scalar IDs and relationships in the private store.
9. Invitee adds book: verify book has household/member/app-user scalar IDs and relationships in the shared store.
10. Block another member write: choose another member and verify Add/Save is disabled or shows the visible authorization error.
11. iCloud disabled/unavailable: verify app routes to the iCloud-required state instead of creating disconnected local identities.
12. Migration failure path: use an intentionally incompatible dev store and verify logs show store URL/configuration/metadata without deleting data.
13. Store load failure recovery screen path: install/run with an intentionally incompatible development store and verify the app shows the Data Recovery screen instead of crashing; confirm diagnostics include store file, configuration, and error domain/code.
14. Signed-out invite link resume flow: fresh install, open an invite link while signed out, verify the invite is captured, sign in with Apple, and verify the invite acceptance sheet is re-presented automatically.
15. Signed-out manual invite resume flow: fresh install, manually enter the invite token/code while signed out, verify the app asks for Sign in with Apple, sign in, and verify the saved invite resumes.
16. Cancel pending invite flow: open or enter an invite, tap the explicit Cancel Invite action, verify the invite is cleared and does not reappear after relaunch/sign-in.
