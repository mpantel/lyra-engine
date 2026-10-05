# Testing Guide for the Lyra Monorepo

This document describes how to run the test suites of Lyra and its component
gems, and of the example applications that exercise Lyra end to end.

## Overview

The repository holds three gems, each with its own Minitest suite:

1. **Lyra** (`orfeas_lyra`, the root): the Rails engine
2. **PAM DSL** (`orfeas_pam_dsl`, `gems/pam_dsl/`): the privacy policy DSL
3. **PetriFlow** (`orfeas_petri_flow`, `gems/petri_flow/`): Petri nets and matrix analysis

All three use **Minitest** with:
- `minitest-reporters`: spec-style console output and JUnit XML reports
- `mocha`: mocking and stubbing (Lyra only)
- `simplecov`: coverage

Each gem's `Rakefile` defines `test` with `Rake::TestTask` over
`test/**/*_test.rb`. The gems have no Gemfile of their own; they run from the
root bundle.

The example applications have their own suites: the Aegean e-Pay testbed and
the BPI 2017 loan application (Minitest), and the Solidus case study (RSpec).
They, `lib/tasks/testbed.rake` and the tasks it defines exist only in the
monorepo, not in the public `lyra-engine` repository.

## Prerequisites: PostgreSQL

The engine's tests load the dummy application in `test/dummy` and its schema,
so they need PostgreSQL as configured in `test/dummy/config/database.yml`:
host `localhost`, port `5433`, user and password `postgres`, database
`lyra_test`.

```bash
bundle exec rake docker:start    # starts the lyra_postgres container (docker-compose.yml) on port 5433
docker exec lyra_postgres createdb -U postgres lyra_test   # once, if the database does not exist yet
```

`rake docker:status`, `docker:stop`, `docker:logs`, `docker:psql` and
`docker:clean` manage the same container. The PAM DSL and PetriFlow suites do
not need a database.

## Running Tests

### All three gems

```bash
bundle exec rake test:all   # Lyra, then PAM DSL, then PetriFlow
bin/test                    # PetriFlow, PAM DSL, then Lyra; exits non-zero if any fails
```

At the time of writing the engine suite has 1168 tests, PAM DSL 448 and
PetriFlow 407.

### One gem

**Lyra:**
```bash
bundle exec rake test               # every test/**/*_test.rb
bundle exec rake test:unit          # everything except test/controllers
bundle exec rake test:controllers   # test/controllers only
```

**PAM DSL:**
```bash
cd gems/pam_dsl
bundle exec rake test
bundle exec rake test:polyfill   # the same suite, forcing the ActiveSupport-free polyfill
bundle exec rake test:both       # test, then test:polyfill
```

**PetriFlow:**
```bash
cd gems/petri_flow
bundle exec rake test
```

### Lyra without PAM DSL

PAM DSL is optional. `LYRA_DISABLE_PAM_DSL=true` loads Lyra without it:

```bash
LYRA_DISABLE_PAM_DSL=true bundle exec rake test
bundle exec rake test:without_pam_dsl   # monorepo only: the same run, with a pass/fail summary
```

### Lyra without PetriFlow

PetriFlow is optional too. `LYRA_DISABLE_PETRI_FLOW=true` loads Lyra as without
the gem: the engine then neither autoloads nor eager-loads `app/workflows`, and
formal verification is unavailable. It parallels `LYRA_DISABLE_PAM_DSL`; no
rake task runs the suite with it. `test/integration/lyra_without_petri_flow_test.rb`
boots the dummy app with the switch in a subprocess and eager-loads it.

### Trace conformance

`test/verification/trace_conformance_test.rb` records the steps Lyra takes on
real writes in Monitor, Hijack and the four event-sourcing projection modes
(the event built, applied to the aggregate, stored, the row written, the
commit) and replays each trace with PetriFlow on that mode's Petri net: every
step must fire an enabled transition and the last must leave the token in the
net's final place. It runs as part of `rake test` and is skipped without
PetriFlow.

### Specific files and methods

```bash
# Lyra
bundle exec ruby -Ilib:test test/configuration_test.rb
bundle exec ruby -Ilib:test test/event_test.rb --name test_event_creation_with_data

# PAM DSL
cd gems/pam_dsl && bundle exec ruby -Ilib:test test/policy_test.rb

# PetriFlow
cd gems/petri_flow && bundle exec ruby -Ilib:test test/core/net_test.rb
```

## The seven configurations

Lyra has four modes (disabled, monitor, hijack, event sourcing); event
sourcing has four projection modes, so there are seven configurations. See
[API_REFERENCE.md](API_REFERENCE.md#the-seven-configurations).

| Configuration | LYRA_MODE | LYRA_PROJECTION_MODE |
|---|---|---|
| Disabled | `disabled` | – |
| Monitor | `monitor` | – |
| Hijack | `hijack` | – |
| ES-Sync | `event_sourcing` | `sync` |
| ES-Async | `event_sourcing` | `async` |
| ES-NoProj | `event_sourcing` | `disabled` |
| ES-Lazy | `event_sourcing` | `lazy` |

The environment variables are read by the Aegean testbed's initializer. The
engine's own tests do not read them: each test sets the mode it needs
(`Lyra.config.mode = ...`), and multi-mode tests such as
`test/multi_mode_test.rb` and `test/integration/multi_mode_integration_test.rb`
switch between configurations themselves.

### Multi-configuration tasks (monorepo only)

These tasks are defined in `lib/tasks/testbed.rake` (root) and
`examples/aegean_epay_testbed/lib/tasks/lyra_test.rake` (testbed).

| Task | What it runs |
|---|---|
| `bundle exec rake test:all_modes` | The engine suite once, then the testbed suite in all seven configurations with `LYRA_MODE` and `LYRA_PROJECTION_MODE` set (resetting the test database between them). Prints how many of the eight runs passed. |
| `bundle exec rake test:without_pam_dsl` | The engine suite once with `LYRA_DISABLE_PAM_DSL=true`. |
| `bundle exec rake lyra:testbed:mode` | The testbed suite once, in `LYRA_MODE` (and `LYRA_PROJECTION_MODE` if set). |
| `bundle exec rake lyra:testbed:integration` | The testbed's `test/integration` only. |
| `bundle exec rake lyra:testbed:all_modes` | Installs the testbed's assets, then runs its `lyra:test:all_modes`. |
| `cd examples/aegean_epay_testbed && bundle exec rake lyra:test:all_modes` | The testbed suite in all seven configurations: Disabled, Monitor, Hijack, ES-Sync, ES-Async, ES-NoProj and ES-Lazy (named "Lyra Disabled", "Monitor Mode", "Hijack Mode", "Event Sourcing (Sync)", "Event Sourcing (Async)", "Event Sourcing (No Projections)", "Event Sourcing (Lazy Projections)"). |
| `bundle exec rake test:comprehensive` | Four phases: the engine suite once; PAM DSL and PetriFlow; the testbed suite in all seven configurations (resetting the test database between them); the engine suite once without PAM DSL. Writes a Markdown report to `examples/aegean_epay_testbed/reports/comprehensive_test_<timestamp>.md`. |

The engine suite runs once because its tests set their own mode: run once
per configuration, it gave the same tests, all passing, each time.

The testbed suite has 567 tests (plus 76 system tests). For each configuration,
`lyra:test:all_modes` prints a line with the test, assertion, failure, error
and skip counts and the duration, then a table of the results by
configuration, the totals, any failing configurations with their
environment variables, and "ALL CONFIGURATIONS PASSED" or the number that
failed. It exits non-zero if any configuration failed.

The testbed runs against the same PostgreSQL container (port 5433); start it
with `bundle exec rake docker:start` first.

## Example application suites (monorepo only)

**BPI 2017 loan application** (`examples/bpi2017_loan_app`, 31 tests). Its
database is PostgreSQL on port 5435 (`config/database.yml`):

```bash
cd examples/bpi2017_loan_app
RAILS_ENV=test bin/rails db:prepare
bin/rails test
```

The tests replay `test/fixtures/files/mini_bpi2017.xes`, a hand-written
miniature log; no real data is in the repository.

**Solidus case study** (`examples/solidus_case_study`, RSpec, 346 examples).
Its database is PostgreSQL on port 5434. The asset pipeline needs a
JavaScript runtime such as Node (ExecJS), and the JavaScript system specs need
Chrome. Where a local headless Chrome cannot start, `bin/rspec-chrome-docker`
runs the specs against Chrome in a Selenium container:

```bash
cd examples/solidus_case_study
bundle exec rspec                  # without a Selenium container
bin/rspec-chrome-docker            # spec/system
bin/rspec-chrome-docker spec       # the whole suite
```

See the README of each application for its setup.

## Test structure

### Directory layout

```
test/                               # Lyra
├── test_helper.rb                  # loads test/dummy, its schema and the engine
├── *_test.rb                       # unit tests, one file per component
├── controllers/                    # dashboard, flow and privacy controllers
├── integration/                    # end-to-end write paths, multi-mode, without PAM DSL
├── interceptors/
├── privacy/
├── projections/
├── schema/
├── tasks/                          # rake tasks (erase, workflow generator)
├── verification/                   # bypass and CRUD lifecycle nets; trace conformance of each mode
├── fixtures/
└── dummy/                          # minimal Rails application (config, db/schema.rb)

gems/pam_dsl/test/
├── test_helper.rb
└── *_test.rb                       # policy, field, consent, retention, registry, enforcement,
                                    # GDPR compliance, PII detector and masker, reporter, ...

gems/petri_flow/test/
├── test_helper.rb
├── registry_test.rb, verification_runner_test.rb, workflow_test.rb
├── colored/                        # arc expressions, colors, colored nets, guards
├── core/                           # net_test.rb
├── export/                         # CPN Tools, JSON, PNML, YAML exporters
├── generators/                     # workflow_generator_test.rb
├── matrix/                         # correlation, lineage
├── simulation/                     # simulator, trace
└── verification/                   # liveness checker, reachability analyzer
```

### Test helpers

Each gem's `test_helper.rb` sets up SimpleCov, requires the library and
configures Minitest reporters (`SpecReporter` and `JUnitReporter`).

### Logging

The test environments of `test/dummy` and of the example applications log at
`:warn`, so test logs hold warnings and errors only.

## Test reports

`JUnitReporter` writes JUnit XML to each suite's `test/reports/` directory
(`test/reports/` and `gems/*/test/reports/`), which CI tools can consume. The
directories are gitignored.

## Continuous Integration

`.github/workflows/test.yml` runs on pushes and pull requests to `master`. It
runs `bundle exec rake test:all` on Ruby 4.0 (the gemspecs' floor; the project
runs 4.0.7 from `.ruby-version`), against a PostgreSQL 16 service
on port 5433 with the `lyra_test` database, and uploads the JUnit XML reports
as artifacts.

## Writing tests

### Basic structure

```ruby
require "test_helper"

module YourModule
  class YourClassTest < Minitest::Test
    def setup
      @instance = YourClass.new
    end

    def test_something
      assert_equal expected_value, @instance.do_something
    end

    def test_raises_error
      assert_raises(SomeError) { @instance.problematic_method }
    end
  end
end
```

### Mocks (Lyra only)

```ruby
def test_with_mock
  mock_object = mock("description")
  mock_object.expects(:method_name).with(arg).returns(value)
  # Mocha verifies expectations automatically
end

def test_with_stub
  object = SomeClass.new
  object.stubs(:method).returns(stubbed_value)
end
```

### Modes in tests

Switch modes with the raw setter (`Lyra.config.mode = :hijack`,
`Lyra.config.projection_mode = :lazy`); it is ungated and records nothing.
`Lyra.reset_config!` restores the defaults. In the test environment the
mode-transition gate and ModeSync are off, and `:async` projections run inline
unless `config.async_projections_inline = false`. See
[MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#testing-during-the-migration).

## Adding new tests

1. Create the file under `test/` (Lyra), `gems/pam_dsl/test/` or
   `gems/petri_flow/test/`, named `*_test.rb`.
2. `require "test_helper"` and define a class inheriting from
   `Minitest::Test` (or `ActiveSupport::TestCase` where the suite uses it).
3. Run it with `bundle exec ruby -Ilib:test path/to/file_test.rb`, then the
   whole suite with `bundle exec rake test`.

## Troubleshooting

### Tests not found

Test files must be under `test/`, end in `_test.rb`, require `test_helper`,
and define classes inheriting from a Minitest test class.

### Database connection errors in the engine suite

Start PostgreSQL with `bundle exec rake docker:start` and check that the
`lyra_test` database exists on port 5433.

### Load errors

Run `bundle install` at the root, and check the load paths in `test_helper.rb`.
