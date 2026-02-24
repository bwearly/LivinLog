# CloudKit Sharing Blank Sheet Investigation

## What was instrumented

### `Livin Log/Views/Settings/UICloudSharingControllerRepresentable.swift`
- Added a single-entry `finish` path that logs whether `share` and `error` are nil/non-nil and logs callback thread (main/background).
- Added NSError/CKError detail logging in `finish` and in share creation/fetch failure paths.
- Added an 8-second watchdog timeout inside `prepareShare` that logs timeout and completes with an explicit error if share preparation stalls.
- Added persistence/shareability diagnostics before sharing:
  - household objectID
  - `isTemporaryID`
  - `context.hasChanges`
  - whether permanent IDs were obtained
  - whether `context.save()` ran before share operations
- Added `fetchShares` diagnostics:
  - returned dictionary keys
  - whether the target objectID key exists
  - whether the mapped share is nil/non-nil
  - existing share recordID when reused
- Added a temporary debug switch `alwaysCreateNewShare` (default `false`) to bypass reuse for stale-share testing.
- Switched `CKContainer` used by the sheet to derive from persistent store configuration, and log the identifier used.

### `Livin Log/Data/PersistenceController.swift`
- Added startup diagnostics to log:
  - app bundle identifier
  - persistent container name
  - CloudKit container identifier configured for stores
  - each loaded store URL + scope + CloudKit container identifier

## What each log proves

- `prepareShare.finish ...`: proves completion callback semantics and guards against nil/nil ambiguity or callback omission.
- Watchdog timeout log: proves whether a blank UI came from a preparation callback that never completed.
- objectID + temporary/permanent + save logs: proves the share root object is persisted and shareable before CloudKit operations.
- `fetchShares` key/value logs: proves whether reuse is happening, and whether stale mappings may be involved.
- NSError/CKError logs: captures actionable CloudKit failure causes (including production schema/account/container issues).
- Persistence startup logs: proves container and store configuration consistency at runtime.

## Ranked root-cause hypotheses and confirmation steps

1. **Preparation callback not invoked correctly (or nil share + nil error).**
   - Confirm via `prepareShare.finish` logs and watchdog timeout.
   - If watchdog fires, callback path is stalling.

2. **Household object not persisted/shareable before share call.**
   - Confirm with `isTemporaryID`, `obtainPermanentIDs`, and `context.save()` logs.

3. **Stale `CKShare` reused from `fetchShares`.**
   - Confirm by observing reuse logs and share recordID behavior.
   - Toggle `alwaysCreateNewShare=true`; if blank sheet disappears, stale reuse is likely root cause.

4. **CloudKit production schema/container mismatch in TestFlight.**
   - Confirm via startup container/store logs + CKError details in production builds.
   - Validate Production schema deployment in CloudKit Dashboard.

5. **Device account/permissions issue.**
   - Confirm through CKError output and account-status UI/log behavior on affected device.

## Minimal execution plan

### Phase 1 (one build): Instrument only
1. Ship this diagnostics build to TestFlight.
2. Reproduce on owner device and collect logs around Invite Member.
3. Reproduce recipient acceptance and verify `userDidAcceptCloudKitShareWith` / accept-invite logs.

Expected outcome: conclusive evidence whether failure is callback flow, persistence state, stale share reuse, or CloudKit environment/account issue.

### Phase 2 (single targeted fix chosen from evidence)
- If stale share: temporarily force new share (`alwaysCreateNewShare=true`) and/or add a minimal reset-share path.
- If temporary/persistence issue: keep enforced permanent-ID + pre-share save path.
- If schema/env mismatch: deploy schema to Production and verify container IDs match all app targets/entitlements.
- If nil/nil callback: always map to explicit error and keep watchdog.

### Phase 3: Acceptance validation
- Validate recipient flow on second Apple ID/device:
  - invite received
  - app opens
  - `userDidAcceptCloudKitShareWith` fires
  - `acceptShareInvitations(... into: sharedStore)` succeeds

## Phase 1 implementation update (this change set)

- Set `share.publicPermission = .readWrite` in both paths in `prepareShare`:
  - when reusing `existingShare`
  - when creating a new `CKShare`
- Added explicit logs in share preparation for:
  - `share.recordID.recordName`
  - `share.publicPermission`
  - `share.url` (or `nil`)
  - resolved CloudKit `containerIdentifier`
- Added route-availability logging at sheet presentation time:
  - `MFMessageComposeViewController.canSendText()`
  - `MFMailComposeViewController.canSendMail()`
- Expanded `UICloudSharingControllerDelegate` logs to include share details in:
  - `cloudSharingControllerDidSaveShare`
  - `cloudSharingController(_:failedToSaveShareWithError:)`
- Preserved single-completion behavior (`finish` lock + `didFinish` guard), and removed an unreachable duplicate completion path in the `fetchShares` closure.

## Device test checklist (to run on physical device)

1. Open Settings → Invite Member.
2. Capture logs for:
   - `Share routes availability canSendText=... canSendMail=...`
   - `Prepared new CKShare ... publicPermission=... url=...`
   - `Reusing existing CKShare ... publicPermission=... url=...`
   - `UICloudSharingController didSaveShare ...`
   - `UICloudSharingController failedToSaveShareWithError ...` (if any)
3. Determine hypothesis outcome:
   - If routes unavailable **and** `url=nil`, Hypothesis 1/2 likely true.
   - If `publicPermission` is set but `url` remains nil after save, investigate share/container validity (Hypothesis 3).
