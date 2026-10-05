# Blog example for Lyra

A small Rails 8.1 application (users, posts, comments; models only, no views)
that runs Lyra in **Monitor** mode. The tables stay authoritative and every
write behaves as it would without Lyra; after each create, update or destroy of
a monitored model Lyra appends an event to that record's stream,
`"Model$id"` (for example `"Post$1"`), in RailsEventStore.

It shows:

- `monitor_with_lyra` in the models (`app/models/`) and a Monitor
  initializer (`config/initializers/lyra.rb`) with `Lyra::EventSerializer` and
  a `metadata_proc`;
- reading a record's stream, comparing the row with its replayed events
  (`Lyra::DualView`), and rebuilding a record as it was (`Lyra.state_at`,
  `Post.as_of`);
- in the tests, the same writes in **Hijack** mode, where the event is
  appended first and the row is written after it.

The rest of the path (Genesis, the mode check, Hijack and event sourcing in
production) is in the Lyra guides linked at the end.

## Requirements

- Ruby 4.0 or later (developed on Ruby 4.0.7), Bundler.
- PostgreSQL. The app uses the PostgreSQL container from the repository's
  `docker-compose.yml` (`lyra_postgres`, `localhost:5433`, user and password
  `postgres`) and creates the databases `blog_app_development` and
  `blog_app_test` in it. For another server, set `DATABASE_HOST`,
  `DATABASE_PORT`, `DATABASE_USER` and `DATABASE_PASSWORD`.

The Gemfile loads Lyra (`orfeas_lyra`, from `../..`) and PetriFlow
(`orfeas_petri_flow`, from `../../gems/petri_flow`) from this checkout, and pins
Rails 8.1.3.1 and RailsEventStore 3.1, the versions Lyra is tested with.
PetriFlow is optional for Lyra itself, but Lyra's rake tasks (`lyra:repair`,
`lyra:genesis`, ...) eager load the engine, which needs it.

## Setup

From the repository root, start PostgreSQL:

```bash
docker compose up -d db
```

Then, in `examples/blog_app`:

```bash
bin/setup
```

`bin/setup` runs `bundle install` and `bin/rails db:prepare`, which creates the
development and test databases, loads `db/schema.rb` and seeds the development
database (`db/seeds.rb`: 2 users, 2 posts, 1 comment, 6 events). The same by
hand:

```bash
bundle install
bin/rails db:prepare
```

`bin/setup --reset` drops and rebuilds the development database.

## Tests

```bash
bin/rails test
```

```
4 runs, 12 assertions, 0 failures, 0 errors, 0 skips
```

`test/models/post_test.rb` checks that creating, publishing and destroying a
post append `PostCreated`, `PostUpdated` and `PostDestroyed` to `"Post$id"`;
that `Lyra::DualView` finds the row and its stream in agreement; that
`Lyra.state_at` returns the post as it was before an update; and that in
Hijack (switched with the raw setter `Lyra.config.mode = :hijack`, which is
for tests only) the event is appended and the row written. Each test runs in a
rolled-back transaction, events included.

## A console walk-through

After `bin/setup`, in `bin/rails console`:

```ruby
post = Post.create!(user: User.first, title: "Hello", body: "First post")
post.publish!

events = Lyra.config.event_store.read.stream("Post$#{post.id}").to_a
events.map(&:event_type)
# => ["Lyra::Events::PostCreated", "Lyra::Events::PostUpdated"]
events.last.data["changes"]["status"]   # => ["draft", "published"]
events.last.metadata[:source]           # => "blog_app", from config.metadata_proc

# The row against the state replayed from its events
Lyra::DualView.new(Post, post.id).compare[:differences]
# => {no_differences: true}
Lyra::DualView.find_discrepancies(Post) # => [] (every post)

# The post as it was when it was created
created_at = events.first.timestamp
Lyra.state_at(Post, post.id, created_at)["status"]  # => "draft"
Post.as_of(created_at).find(post.id).status         # => "draft"
```

The helpers `event.operation`, `event.changes` and `event.attributes` are
available on events whose class (`Lyra::Events::PostUpdated`, ...) the process
has already defined, which happens on its first write to that model. In a
fresh console that has only read, the events come back as plain
`RubyEventStore::Event`; `event.data` has the same content either way.

The same check over every monitored record (the 5 seeded and the post above), from the shell:

```bash
bin/rails lyra:repair DRY_RUN=1
# checked 6 records: 0 out of line, 0 repaired, 0 still out of line
```

## Files

- `Gemfile`: Rails, pg, RailsEventStore, Lyra and PetriFlow.
- `config/initializers/lyra.rb`: Monitor mode, the event store, metadata.
- `app/models/`: `User`, `Post`, `Comment`, each with `monitor_with_lyra`.
- `db/migrate/`: the RailsEventStore 3 tables (from
  `bin/rails generate ruby_event_store:active_record:migration`) and the
  application's tables. Lyra creates its own tables
  (`lyra_mode_transitions`, `lyra_projection_checkpoints`) on first use.
- `test/models/post_test.rb`: the tests above.

## Further reading

- [Getting Started](../../docs/GETTING_STARTED.md): installing Lyra and
  Monitor mode, step by step.
- [Migration Guide](../../docs/MIGRATION_GUIDE.md): from Monitor to Hijack and
  event sourcing, through the mode check.
- [API Reference](../../docs/API_REFERENCE.md): every option, method and rake
  task.
- [Testing](../../docs/TESTING.md) and
  [Troubleshooting](../../docs/TROUBLESHOOTING.md).
