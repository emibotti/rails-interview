# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A small Todo List API in Rails 7.0 (Ruby 3.1, SQLite), used as a starting point for Crunchloop's Ruby full-stack candidate interviews. External integration tests that exercise the API live in https://github.com/crunchloop/interview-tests, so the JSON API's shape (routes, field names, status codes) is a contract to preserve.

## Commands

- Setup (install gems, prepare DB, seed): `bin/setup`. The devcontainer runs `bundle install && bundle exec rake db:setup` on creation.
- Run server: `bin/puma` (port 3000)
- Run all tests: `bin/rspec`
- Run one file / one example: `bin/rspec spec/controllers/api/todo_lists_controller_spec.rb` or `bin/rspec spec/controllers/api/todo_lists_controller_spec.rb:20`
- Migrations: `bin/rails db:migrate` (updates `db/schema.rb`); test schema is kept in sync automatically via `maintain_test_schema!`.
- Bulk test data: `bin/rails "dev:seed_items[LIST_ID,COUNT]"` inserts COUNT pending items with `insert_all` (creates a new list if LIST_ID is blank). Use 100k+ items to see the mark all progress bar move.

There is no linter configured.

## Architecture

The same resource is served through two parallel controller stacks:

- `Api::TodoListsController` (`/api/todolists`): JSON only, full CRUD (no `new`/`edit`), rendered with Jbuilder views in `app/views/api/`.
- `Api::TodoItemsController` (`/api/todolists/:todo_list_id/todoitems`): JSON only, full CRUD nested under a list. Items are always looked up through `@todo_list.todo_items`, so an item from another list is a 404.
- `TodoListsController` (`/todolists`): HTML only (`index`, `new`, `show` with items paginated 25 per page inside a Turbo Frame, `POST complete_all`), ERB views in `app/views/todo_lists/`. Items have no HTML CRUD.

Note the routes use `path: :todolists` / `path: :todoitems` (no underscore) while controllers, models and route helpers use `todo_lists` / `todo_items`.

Each action restricts its format with `respond_to :json` / `respond_to :html`. `ApplicationController` rescues `ActionController::UnknownFormat` and re-raises it as `ActionController::RoutingError('Not supported format')`, so requesting the wrong format surfaces as a routing error (404). The specs assert this behavior. Both controllers inherit from `ActionController::Base` (not `API`), so CSRF protection applies to non-GET requests.

Tests use RSpec with transactional fixtures: controller specs for the API (`render_views` enabled so Jbuilder output is checked), request specs for the HTML stack, job and model specs. The test env uses the `:test` Active Job adapter (`perform_enqueued_jobs`, `have_enqueued_job`) and the `test` Action Cable adapter (`have_broadcasted_to(record.to_gid_param)` for Turbo Streams). There is no Chrome in the devcontainer (arm64), so there are no JS system specs; the Stimulus controller is verified by hand. `rspec-rails` is declared in the `:development` Gemfile group, not `:test`.

### API conventions

- Both API controllers use `protect_from_forgery with: :null_session` so external clients can POST/PATCH/DELETE without a CSRF token.
- Status codes: `create` 200 (matches the external Postman collection), `destroy` 204 (no body), invalid data 422 with `{ "errors": { field: [messages] } }`, missing record (list or item) 404 with `{ "error": "Not found" }` via `rescue_from ActiveRecord::RecordNotFound`.
- Write params are accepted flat (`{ "name": "x" }`) or nested (`{ "todo_item": { "name": "x" } }`); only `name` (and `completed` for items) are permitted.
- Both `index` actions are paginated through the `Paginable` concern: 25 records per page ordered by `id`, `?page=N` (invalid values fall back to page 1, pages past the end return `[]`). The body stays a plain array; metadata goes in the `X-Total-Count`, `X-Total-Pages`, `X-Page`, `X-Per-Page` and `Link` headers.
- Jbuilder responses: lists expose `id, name` only (the index shape is a contract); items expose `id, name, description, completed, todo_list_id, created_at, updated_at`. `description` is an alias of `name` (accepted as a param, returned with the same value), and items are also served under the `/todos` path as an alias of `/todoitems`, both to match the external Postman collection.

### Models

- `TodoList` `has_many :todo_items, dependent: :destroy` and validates `name` presence.
- `TodoItem` `belongs_to :todo_list`, validates `name` presence; `completed` is `null: false, default: false`.

### Mark all (Hotwire + Action Cable)

`POST /todolists/:id/complete_all` marks every pending item of a list as completed without touching items in the request:

- It takes a per-list lock (`todo_lists.mark_all_heartbeat_at`, acquired with a conditional `UPDATE`), and enqueues a single `CompleteAllTodoItemsJob` with the current max pending item id, so items created later are not affected. It responds 202, 409 if a run is already in progress, or 200 if nothing is pending.
- The job updates in batches of 1000 (`in_batches` + `update_all`, setting `updated_at` by hand, filtered by `completed: false` so it is idempotent), refreshing the heartbeat and broadcasting a progress status via Turbo Streams after each batch, then a final `done` status. A lock with a heartbeat older than `TodoList::MARK_ALL_STALE_AFTER` is considered abandoned.
- The 202/409 responses are empty turbo streams on purpose: the status element is only replaced by job broadcasts, so a late HTTP response can't overwrite `done`.
- `mark_all_controller.js` keeps the button disabled while running (re-applying it on `turbo:submit-end`, since Turbo re-enables the submitter) and reloads the items frame at the current URL on `done` (pagination links use `data-turbo-action="advance"`).

No queue backend or Redis: in development, jobs run on the default `:async` adapter and Action Cable on the `async` adapter, both inside the Puma process (a Puma restart loses a running job; the stale lock recovers from it). Because of that:

- `config/initializers/sqlite3.rb` backports Rails 8.0's SQLite setup: WAL plus a busy handler that sleeps in Ruby (Rails 8.0 uses sqlite3 2.x `busy_handler_timeout`). The sqlite3 1.x `busy_timeout` holds the GVL while waiting, which deadlocks a job and a request until the timeout expires; Rails 7.1/7.2 still use it, so the initializer can only be removed when upgrading to Rails 8.0.
- The job calls `Thread.pass` after each batch; without it, SQLite holding the GVL starves concurrent requests until the job ends.

## Git

Recent history uses Conventional Commits style (`chore(doc): ...`). Don't commit unless asked, and leave unrelated working-tree changes (devcontainer, lockfile) out of feature commits.
