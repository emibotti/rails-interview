# NOTES

Design notes for the two-way sync between this Todo API and the External Todo API.
This file grows with the implementation: each section describes what exists today.
Sections marked _(planned)_ describe decisions already taken whose code is not written yet.

## High-level overview

- Two-way, **state-based** sync of `TodoList` and `TodoItem` with the External Todo API.
- One idempotent sync cycle _(planned)_: snapshot (one `GET`) → link by `source_id` → apply remote changes →
  push tombstones → push creates → item-creation strategy → push updates. It is triggered by a debounced job after
  local changes and by a periodic reconciliation (rake task + cron) as a safety net.
- Components:
  - `ExternalTodo::*` (`app/services/external_todo/`): HTTP client, mapper and value objects. The only code that knows the external wire format.
  - `Syncable` concern + `sync_*` tables: local change tracking.
  - `TodoSync::*` _(planned)_: the sync engine.
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

Tests: `bin/rspec` (the external API is faked in-process with WebMock; the sync is disabled in the test environment
unless a spec enables it).
