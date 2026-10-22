# rails-interview / TodoApi

[![Open in Coder](https://dev.crunchloop.io/open-in-coder.svg)](https://dev.crunchloop.io/templates/fly-containers/workspace?param.Git%20Repository=git@github.com:crunchloop/rails-interview.git)

This is a simple Todo List API built in Ruby on Rails 7. This project is currently being used for Ruby full-stack candidates.

## Build

To build the application:

`bin/setup`

## Run the API

To run the TodoApi in your local environment:

`bin/puma`

## Test

To run tests:

`bin/rspec`

Check integration tests at: (https://github.com/crunchloop/interview-tests)

## Sync with the External Todo API

Lists and items are synced in both directions with an external API (see [NOTES.md](NOTES.md) for the design, trade-offs and assumptions).
There is no real external server, so a fake one plays its role:

```bash
bin/fake_external_api        # terminal 1: http://localhost:4000, state in memory
bin/puma                     # terminal 2: the app, sync on, EXTERNAL_TODO_API_URL defaults to http://localhost:4000
```

Changes made through `/todolists` or `/api/todolists` are synced about 5 seconds later (`curl localhost:4000/todolists`). To run a cycle by hand, or to
bring in what changed in the external API:

```bash
bin/rails todo_sync:run            # one cycle, prints the summary
bin/rails todo_sync:status         # last runs, pending records, tombstones, errors
bin/rails todo_sync:failed         # records that gave up (dead letters) with their error
bin/rails todo_sync:retry_failed   # put them back in play once the cause is fixed
```

Changes made in the external API are only seen by a cycle, so run `todo_sync:run` periodically, for example from cron:

```cron
*/5 * * * * cd /path/to/app && bin/rails todo_sync:run >> log/todo_sync_cron.log 2>&1
```

| Environment variable | Default | Meaning |
|---|---|---|
| `EXTERNAL_TODO_API_URL` | `http://localhost:4000` | Base URL of the external API |
| `TODO_SYNC_ENABLED` | on (off in test) | `false` disables the automatic sync (do it with a very large local database: the first sync uploads everything) |
| `EXTERNAL_TODO_ITEM_CREATION` | `recreate_list` | How items created in an already synced list reach the API: `recreate_list`, `skip` or `api_endpoint` |

The specs fake the external API in-process (`bin/rspec`, no server needed).

## Contact

- Santiago Doldán (sdoldan@crunchloop.io)

## About Crunchloop

![crunchloop](https://s3.amazonaws.com/crunchloop.io/logo-blue.png)

We strongly believe in giving back :rocket:. Let's work together [`Get in touch`](https://crunchloop.io/#contact).
