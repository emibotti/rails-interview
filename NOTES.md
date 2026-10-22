# NOTES

Design notes for the two-way sync between this Todo API and the External Todo API.
This file grows with the implementation: each section describes what exists today.
Sections marked _(planned)_ describe decisions already taken whose code is not written yet.

## High-level overview

- Two-way, **state-based** sync of `TodoList` and `TodoItem` with the External Todo API.
- One idempotent sync cycle: snapshot (one `GET`) → link by `source_id` → apply remote changes →
  push tombstones → push creates → item-creation strategy → push updates. Implemented so far: snapshot, link, pull, push of creates, push of updates, deletes in both directions and conflict resolution. It is triggered by a debounced job after
  local changes and by a periodic reconciliation (rake task + cron) as a safety net.
- Components:
  - `ExternalTodo::*` (`app/services/external_todo/`): HTTP client, mapper and value objects. The only code that knows the external wire format.
  - `Syncable` concern + `sync_*` tables: local change tracking.
  - `TodoSync::*` (`app/services/todo_sync/`): the sync engine (`Runner`, `Snapshot`, `Linker`, `Puller`, `CreatePusher`, `UpdatePusher`, `TombstonePusher`, `DeletionGuard`, `BulkWriter` so far).
  - `FakeExternalTodoApi` (`lib/`): in-memory fake of the external API, used by the specs and for manual runs.

## Key design decisions

### State-based change tracking, not an outbox
Every record stores its own sync state in columns: `external_id`, `local_version`, `synced_version`, `remote_updated_at`.
A record is **dirty** while `local_version > synced_version`.

- Why a counter and not a `dirty` boolean: the sync reads version 5 and sends it; meanwhile the user edits (version 6).
  When the push succeeds we store `synced_version = 5` (the version *sent*), so the record is still dirty and the next
  cycle sends the newer edit. A boolean would be cleared and that edit would be lost.
- Why not a transactional outbox: it would have to be written on every write path, including `update_all`
  (mark all touches up to 100k rows), and operations would need to be merged and ordered. With state columns,
  several edits of a record collapse into one, the engine can be re-run safely and it self-heals.
  The trade-off is less per-operation audit trail and more columns/indexes.
- Why not `lock_version`: any update bumps it, including the ones the sync does when applying remote changes.
- Why not triggers (CDC) or `updated_at` comparisons: logic in the database / races and precision, and neither sees deletes.
- New and pre-existing rows are born dirty (`local_version` 1, `synced_version` 0), even when created with `insert_all`,
  so the first sync uploads them with no extra code. A partial index (`local_version > synced_version`) keeps the
  "what is dirty" query cheap.
- Future work: store the synced values (`synced_name`, `synced_completed`) to merge field by field (three-way merge).

### Writes that skip callbacks, on purpose
`before_update` bumps `local_version`, but `update_all`, `insert_all` and `update_columns` do not run callbacks.

- The **sync itself** writes remote changes with those methods, so applying a remote change never counts as a local
  change and nothing is echoed back (no infinite ping-pong).
- **Bulk local writes** must bump the version by hand. `CompleteAllTodoItemsJob` does
  `local_version = local_version + 1` in the same `UPDATE`. A spec guards it.

### Hard delete + tombstones, not soft delete
Deleting a synced record (one with `external_id`) deletes the row and, in the same transaction, inserts a `sync_tombstones` row
with the remote id (and the remote list id for items).

- The tombstone is needed because the remote `DELETE` still has to be sent, and because a pull that runs before it
  would otherwise see the record in the remote snapshot and re-import it as new.
- Records that were never synced leave no tombstone (create + delete before a sync = zero API calls).
- Why not soft delete: every query would need a filter (index, `show`, `X-Total-Count`, associations, mark all),
  `default_scope` has known traps, the local API contract would be at risk, and deleting a 100k item list would mean
  flagging 100k rows.
- Trade-off: no undo, and no way to restore the record if the remote `DELETE` fails forever. The tombstone could
  store a JSON copy of the record if that is ever needed.

### Deleting a list is one statement
`TodoList has_many :todo_items, dependent: :delete_all`: a single SQL `DELETE`, no per-item callbacks and no per-item tombstones.
The tombstone of the list is enough, because deleting a list remotely deletes its items. With `dependent: :destroy`,
a 100k item list would load and destroy 100k records and generate 100k tombstones.
`TodoItem` has no destroy callbacks that this skips, other than the tombstone covered above.

### Anti-corruption layer for the external API
`ExternalTodo::Client` returns domain structs (`RemoteList`, `RemoteItem`), never wire hashes. `ExternalTodo::Mapper`
is the only place that knows the external format: `id` → `external_id`, items' `description` ↔ `name`,
ISO8601 strings → `Time` (tolerating `null`, missing fields and odd formats).
The mapper spells the fields out on purpose (7 fields): it is easy to read, specs catch typos, and unknown remote
fields are ignored until we need them. A declarative mapping table would save little and hide the conversions.

### `source_id`
`ExternalTodo::SourceId` builds `"rails-interview:list:<id>"` / `"rails-interview:item:<id>"` and parses them back
(`nil` if it is not ours). The prefix namespaces our ids so they cannot collide with other systems' ids, and lets the
sync recognise what it created itself.

### Jobs stay on the `:async` adapter; state lives in the database
Sidekiq is not introduced now: it needs Redis and a second process, Action Cable's `async` adapter would stop delivering
the mark all progress broadcasts from another process, two processes would write the same SQLite file, and it does not
fix the dual write anyway (the Redis enqueue is not part of the SQLite transaction).
Because a Puma restart loses `:async` jobs, the sync state (what is dirty, which tombstones are pending, the debounce
mark and the lock) lives in SQLite. The job is only a trigger, so losing one loses nothing.
Sidekiq is listed in future work.

### Pull: remote → local (`TodoSync::Puller`)
The cycle starts with one `GET /todolists` and only then writes anything. The pull then:

- **Imports** remote lists/items that are unknown locally, in one short transaction per list, items in batches of 1000
  with `insert_all`. They are born in sync (`local_version = synced_version = 1`, remote `created_at`/`updated_at` kept),
  so they are not dirty and never bounce back to the remote.
- **Detects remote changes** by comparing the snapshot's `updated_at` with the stored `remote_updated_at` (to the millisecond,
  the precision of the wire format), not by comparing every field. A record whose timestamp did not move costs no write at all,
  so running the pull twice writes nothing (a spec counts the `INSERT`/`UPDATE` statements).
- **Applies** a remote change if the record is clean locally, or if it wins a conflict (see "Conflict resolution"). It uses a conditional `UPDATE ... WHERE local_version = <the one read>`:
  if the user edited the record between our read and our write, zero rows match and the next cycle re-evaluates. No lock is held.
- **Never overwrites a dirty record unless the remote is newer.** Otherwise the record is left as it is, with `remote_updated_at` untouched,
  and the push sends it.
- **Skips records created by us** (parseable `source_id`) that are not linked yet: the linker (step 4) binds them to their local record,
  which is how a `POST` that timed out gets recognised without creating duplicates.
- **Skips remote records with a blank name or no id**, with a `warn` and `stats["skipped_invalid"]`. `insert_all` bypasses validations and
  `name` is required locally; importing a placeholder would invent data, so skipping is the conservative choice.
- Calls `Thread.pass` between lists, like the mark all job, because SQLite runs in-process and would otherwise starve Puma's request threads.

Remote deletions are not handled yet (step 6).

`Runner` takes the global lock, wraps the cycle in a `SyncRun` (status, stats, error) and tags the logs with `todo_sync` and `run=<id>`.
If the snapshot cannot be fetched the run is `aborted` and nothing is written: pushing without a fresh snapshot risks duplicates and overwrites.
The lock is always released, including on unexpected errors (the run is then `failed` and the error re-raised).

### Linking by `source_id` and idempotent creates (`TodoSync::Linker`)
The API has no `Idempotency-Key`, so a `POST` that times out is ambiguous: the list may exist remotely. We never re-POST.
Instead the snapshot is fetched first, and any remote list/item whose `source_id` is ours is **linked** to its local record
(only `external_id` and `remote_updated_at` are stored, `synced_version` is not touched; the update pusher marks it synced if
the values already match). The result is a single remote list however many cycles it takes.

- Linking updates are conditional (`WHERE external_id IS NULL`, and `todo_list_id = <that list>` for items), so they are idempotent and
  never re-bind a record.
- **Duplicates:** if two remote lists carry the source_id of the same local list and the one the local record points to is
  still in the snapshot, the other one is ours and a duplicate (an ambiguous POST that was retried by a human, or a list recreated by
  the item-creation strategy). It gets a tombstone, so it is deleted through the normal path. Only records with our prefix are ever
  deleted automatically.
- **Orphans:** a remote record with our `source_id` but no local row (most likely deleted locally before it was ever synced) is left
  alone and logged (`stats["orphans"]`). The prefix cannot distinguish it from a record written by another environment that shares the
  same remote, and deleting someone else's data is worse than leaving a stray record. Local ids are never reused (SQLite
  `AUTOINCREMENT`), so a stray cannot be linked to the wrong record.

### Pushing creates (`TodoSync::CreatePusher`)
Each local list without `external_id` is sent with **all** its items in one `POST` (the only way the API creates items).

- The returned ids are matched to local rows by `source_id`. If the API does not echo `source_id`, it falls back to the order the items
  were sent in (with a `warn`), and if that is impossible the list is linked and the items are linked by the Linker next cycle.
- Everything is saved in one transaction with `synced_version = <version sent>`, never the current one: an edit made while the POST
  was in flight leaves the record dirty, and items created during the POST stay unlinked for the item-creation strategy (step 8).
- Item links are written with `BulkWriter`: one `UPDATE ... FROM (VALUES ...)` per 500 items instead of one `UPDATE` per item, which
  matters for lists with 100k items (a CTE is needed because SQLite has no `AS v(columns)` alias for subqueries).
- A `TimeoutError` is counted and the list is left for the next cycle (to be linked if it was created). A `4xx` or `5xx` is counted as a
  failure and the cycle continues with the next list. Backoff and dead letters come in step 10.
- Trade-off: a list with a huge number of items is one huge request. The plan caps the lists we *recreate* (D9), not the first upload.

### Pushing updates (`TodoSync::UpdatePusher`)
Dirty linked lists and items (items only if their list is linked) are **compared with the snapshot before anything is sent**:

- Remote already has the same values → no call. The record is marked synced with the snapshot's `updated_at`
  (`stats["skipped_noop"]`). Items are marked in batches with `BulkWriter`.
- Otherwise a `PATCH` with **only the fields that differ**. This is what bounds the cost of a mark all: N items, M of them already
  completed remotely, cost exactly N - M requests (a spec checks it), since the API has no bulk operation.
- After a successful `PATCH`, `synced_version` is set to the version read **before** the call, with `WHERE synced_version < version`,
  so an edit made during the request leaves the record dirty and the next cycle sends it (a spec edits the item inside the request).
- A record missing from the snapshot is skipped (it was deleted remotely; the pull deals with it in step 6). A `404` on `PATCH` means it
  vanished after the snapshot: the delete wins (D5), the record is removed locally without callbacks (so no tombstone) and a `warn`
  logs the local version that was dropped.
- A `422` or a persistent `5xx` is counted in `stats["failures"]` and the record stays dirty; the other records go on.
- The loop refreshes the lock heartbeat and calls `Thread.pass` every 100 records.
- Not done: bounded concurrency for the `PATCH`es. It is the main lever for huge mark alls, but SQLite's single writer and the GVL make it
  a measured optimisation rather than a default, so it is listed as future work.

### Deletes in both directions
**Local → remote (`TombstonePusher`).** Each tombstone becomes a `DELETE`; `204` and `404` both mean "gone" and drop the tombstone.

- Coalescing: item tombstones of a list that is also being deleted are dropped with no call (the list `DELETE` removes its items), so
  deleting a 100k item list costs one request. A tombstone whose record is no longer in the snapshot costs no call either.
- A failing `DELETE` keeps the tombstone, counts the attempt, stores the error and sets `next_attempt_at` with exponential backoff
  (30 s doubling, capped at 1 h; jitter and a maximum number of attempts come with step 10). The record is **not resurrected** meanwhile:
  the pull skips remote records that have a tombstone (`stats["skipped_tombstoned"]`), and it logs `delete wins` at `warn` when the remote
  copy was edited after the local delete.

**Remote → local (`Puller`).** The API has no tombstones, so "a linked record is not in the snapshot" is the only signal that it was deleted
remotely. It is then deleted locally with `delete_all` (items before lists, no callbacks, hence no tombstone). If it had unsynced local changes
the delete still wins (D5) and a `warn` says what was dropped, including the number of dirty items of a deleted list.

**Deletion guard (`DeletionGuard`).** A bad response (empty, truncated) looks exactly like a mass delete, so local deletions are refused when
the snapshot is empty but we have linked lists, or when more than 50 % of at least 5 linked lists are missing
(`config.x.todo_sync.guard_*`). The run ends as `aborted_deletions` and an `error` is logged; pushes and imports still happen.
Known cost: if the *only* linked list is deleted remotely it is never deleted locally (the snapshot looks empty); the same happens when
a large share of lists is legitimately deleted at once. Both need a human (or a lower threshold). The guard looks at lists only, not at items.

### Conflict resolution
A conflict exists only when **both sides changed** since the last sync (`local_version > synced_version` and the snapshot's `updated_at` differs from
`remote_updated_at`) **and the values differ**. Changing both sides to the same value is not a conflict and costs no request.

- **Last write wins at record level**, comparing the local `updated_at` with the remote one to the millisecond. A tie goes to the remote
  because it is deterministic. If the remote wins it is applied by the pull (conditional on `local_version`, so an edit that arrives
  meanwhile is not lost) and the local change is discarded with a `warn`. If the local wins the record stays dirty and the push overwrites the remote.
  The pull decides and the push does not look at timestamps, so each side has one place to read.
- **A delete beats an edit, in both directions** (see "Deletes in both directions"); the log says what was dropped.
- If the remote has no `updated_at` there is nothing to compare, so the local change is kept instead of being discarded blindly.
- Every conflict is counted in `stats["conflicts"]` and logged, which is the audit trail.
- Why not something richer: a fixed source of truth loses edits, CRDTs are overkill for a todo list, and a field-level merge needs the last synced
  values (future work, see above). The cost of record-level LWW is that editing *different* fields on both sides keeps only the newer record
  as a whole (e.g. a remote `completed` is lost if the local `name` edit is newer).
- Risk: the two clocks are not the same clock. A remote server running behind ours loses every conflict. Nothing in the API (no ETag or version)
  allows a safer rule.

### Locks with heartbeat
`SyncState` is a single-row table with `scheduled_at` (debounce mark) and `lock_heartbeat_at`. The lock is taken with a
conditional `UPDATE` and is considered abandoned after 5 minutes without a heartbeat, the same pattern as
`TodoList#acquire_mark_all_lock!`. That pattern is now written twice (a few lines each); extracting a shared concern
was considered and left for later, since there are only two uses and it would touch the working mark all code.

## Resilience and error handling

Implemented in `ExternalTodo::Client`:

- Explicit timeouts (`open_timeout` 2 s, `timeout` 10 s).
- **In-request retries only for idempotent calls**: `GET`, `PATCH` (it sends absolute values) and `DELETE`, on connection
  errors, timeouts and 429/500/502/503/504, with exponential backoff and jitter. `Retry-After` is honoured.
  `faraday-retry` does not retry `PATCH` by default, so `methods:` is set explicitly.
- **`POST` is never retried**: it is not idempotent and there is no `Idempotency-Key`. A timeout is ambiguous
  (the record may exist), so the next cycle links it by `source_id` from the fresh snapshot instead of re-posting.
- Error hierarchy: `Error` (with `status`, `body`, `http_method`, `path`) → `RetryableError` (connection, 408, 429, 5xx;
  `TimeoutError` is the ambiguous one) / `ClientError` (other 4xx; `NotFoundError` for 404, whose policy the sync decides)
  / `InvalidResponseError` (invalid JSON or unexpected shape). Messages look like
  `PATCH /todolists/abc/todoitems/x failed with 422: <truncated body>`.
- When retries on a status are exhausted, `faraday-retry` returns the last response instead of raising;
  the client turns it into the proper error.
- Every request is logged (`[ExternalTodo] PATCH /todolists/x -> 200 (12.3ms)`), and retries and failures at `warn`.

Planned: per-record backoff and dead letters, circuit breaker, mass-deletion guard, stale lock recovery.

## Performance

Planned: one `GET` per cycle; a list and its items are created in one `POST`; no-op `PATCH`es are skipped by diffing
against the snapshot; tombstone coalescing; debounce to batch bursts; batched local writes (1000 rows).

## Edge cases

Handled so far (each has a spec):

- Create and delete before any sync: no tombstone, no calls.
- Deleting a synced list: one tombstone for the list and none for its items, without loading the items.
- Registering the same tombstone twice does not fail (unique index + `find_or_create_by!`).
- Editing a record without changing a synced field does not make it dirty.
- Mark all marks exactly the items it completes as dirty, and none of the others.
- Ambiguous POST (created remotely, client saw a timeout): the next cycle links it, with no second POST and no duplicate.
- Edit made while a POST was in flight: the record stays dirty. Items created meanwhile stay unlinked.
- Duplicate remote list with our `source_id`: tombstoned. Remote record with our `source_id` and no local row: left alone and logged.
- A failing POST (422/500) does not stop the other lists, and neither does a failing PATCH.
- A cycle with no changes makes exactly one request (the GET).
- Mark all of N items with M already completed remotely: N - M PATCHes.
- Edit during a PATCH: the record stays dirty and is sent next cycle.
- PATCH answered 404: the record is deleted locally without callbacks and logged.
- Deleting a list with items, or an item and then its list: one `DELETE`.
- `DELETE` answered 404: counted as success. Failing `DELETE`: tombstone kept with backoff, and the pull does not bring the record back.
- Record deleted remotely: deleted locally without a tombstone; a pending local edit is logged and dropped (delete wins).
- Empty or mostly missing snapshot: nothing is deleted locally and the run is `aborted_deletions`.
- Both sides changed: the newest wins, a tie goes to the remote, equal values are not a conflict, and the result is stable on the next cycle.
- Running the pull twice writes nothing; a remote change to a clean record is applied without bumping `local_version`.
- A record dirty locally is not overwritten by a remote change, and neither is one edited while the pull was running.
- Remote records with a blank name or no id are skipped, not imported.
- A POST that was processed but timed out is visible to the client as `TimeoutError` and is not retried.

## Assumptions

- `source_id` is the id of the record in the system that originated it; the API returns it in the `POST` response and in the `GET`.
  Uniqueness is unknown.
- A `DELETE` of a missing resource answers 404 (undocumented), and we treat it as success.
- No documented error format, rate limits or atomicity of `POST` with items; we assume 429/5xx can happen.
- Local and remote clocks are roughly in sync (used for conflict resolution).

## Dependencies

- `faraday` + `faraday-retry` for the client; `webmock` (test group) to run the fake API through the real HTTP stack in specs.
- `json` is pinned to `~> 2.9.1`: Faraday depends on `json`, and `json >= 2.10` dropped the `quirks_mode` option that Rails 7.0
  and Jbuilder 2.11 still pass, which broke every JSON response. Remove the pin when upgrading Rails.

## Suggested changes to the external API

1. `POST /todolists/{id}/todoitems` to create items in an existing list.
2. Bulk operations (`PATCH` many items, or `POST /todolists/{id}/complete_all`).
3. `GET /todolists?updated_since=` with cursor pagination and tombstones (`deleted_at`), for incremental sync.
4. `ETag`/`If-None-Match` on the `GET` and `If-Match` on `PATCH`/`DELETE`.
5. `Idempotency-Key` on `POST`, and unique `source_id` (or a `PUT` by `source_id`).
6. Webhooks for remote changes.
7. Document the error format, rate limits, atomicity of `POST` with items and the meaning of `source_id`.
8. A single-resource `GET /todolists/{id}`.

## Areas for improvement / future work

- Sidekiq (with Redis for Action Cable): jobs that survive restarts, work outside Puma, native retries and a dead set.
- Field-level three-way merge, streaming JSON parsing for huge snapshots, persistent connections or bounded concurrency for mass `PATCH`es.
- Soft delete / undo through tombstone payloads; admin UI for dead letters; metrics.
- Extract the heartbeat lock shared by `TodoList` and `SyncState` into a concern.

## How to run

The fake external API:

```bash
bin/fake_external_api                    # http://localhost:4000, state in memory
FAKE_SUPPORTS_ITEM_CREATION=true bin/fake_external_api   # also serves the proposed POST /todolists/:id/todoitems
EXTERNAL_TODO_API_URL=http://localhost:4000 bin/puma
```

Run one sync cycle (link, pull, push creates): `bin/rails todo_sync:run` (prints the run summary).

Tests: `bin/rspec` (the external API is faked in-process with WebMock; the sync is disabled in the test environment
unless a spec enables it).
