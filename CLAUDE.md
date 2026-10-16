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

There is no linter configured.

## Architecture

The same resource is served through two parallel controller stacks:

- `Api::TodoListsController` (`/api/todolists`): JSON only, full CRUD (no `new`/`edit`), rendered with Jbuilder views in `app/views/api/`.
- `Api::TodoItemsController` (`/api/todolists/:todo_list_id/todoitems`): JSON only, full CRUD nested under a list. Items are always looked up through `@todo_list.todo_items`, so an item from another list is a 404.
- `TodoListsController` (`/todolists`): HTML only (`index`/`new`), ERB views in `app/views/todo_lists/`. There is no HTML UI for items.

Note the routes use `path: :todolists` / `path: :todoitems` (no underscore) while controllers, models and route helpers use `todo_lists` / `todo_items`.

Each action restricts its format with `respond_to :json` / `respond_to :html`. `ApplicationController` rescues `ActionController::UnknownFormat` and re-raises it as `ActionController::RoutingError('Not supported format')`, so requesting the wrong format surfaces as a routing error (404). The specs assert this behavior. Both controllers inherit from `ActionController::Base` (not `API`), so CSRF protection applies to non-GET requests.

Tests are RSpec controller specs (`render_views` enabled so Jbuilder output is checked) with transactional fixtures. `rspec-rails` is declared in the `:development` Gemfile group, not `:test`.

### API conventions

- Both API controllers use `protect_from_forgery with: :null_session` so external clients can POST/PATCH/DELETE without a CSRF token.
- Status codes: `create` 201, `destroy` 204 (no body), invalid data 422 with `{ "errors": { field: [messages] } }`, missing record (list or item) 404 with `{ "error": "Not found" }` via `rescue_from ActiveRecord::RecordNotFound`.
- Write params are accepted flat (`{ "name": "x" }`) or nested (`{ "todo_item": { "name": "x" } }`); only `name` (and `completed` for items) are permitted.
- Both `index` actions are paginated through the `Paginable` concern: 25 records per page ordered by `id`, `?page=N` (invalid values fall back to page 1, pages past the end return `[]`). The body stays a plain array; metadata goes in the `X-Total-Count`, `X-Total-Pages`, `X-Page`, `X-Per-Page` and `Link` headers.
- Jbuilder responses: lists expose `id, name` only (the index shape is a contract); items expose `id, name, completed, todo_list_id, created_at, updated_at`.

### Models

- `TodoList` `has_many :todo_items, dependent: :destroy` and validates `name` presence.
- `TodoItem` `belongs_to :todo_list`, validates `name` presence; `completed` is `null: false, default: false`.

## Git

Recent history uses Conventional Commits style (`chore(doc): ...`). Don't commit unless asked, and leave unrelated working-tree changes (devcontainer, lockfile) out of feature commits.
