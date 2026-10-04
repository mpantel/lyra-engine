# Lyra

**CRUD to Event Sourcing Transformation Engine**

*Part of the ORFEAS (Object-Relational to Event-Sourcing Architecture) Framework*

Lyra is a Rails engine that records the writes an ActiveRecord application
makes as events (RailsEventStore), and can then move the application, one
checked step at a time, to treating those events as the source of truth.

---

## Modes

The mode is application-wide. Per model you choose only whether it is
monitored (`monitor_with_lyra` in the model, or `config.models=` in the
initializer). Event sourcing takes one of four projection modes, which gives
seven configurations:

| Configuration | `mode` | `projection_mode` | Authoritative store |
|---|---|---|---|
| Disabled | `:disabled` | – | tables |
| Monitor | `:monitor` (default) | – | tables |
| Hijack | `:hijack` | – | events |
| ES-Sync | `:event_sourcing` | `:sync` (default) | events |
| ES-Async | `:event_sourcing` | `:async` | events |
| ES-NoProj | `:event_sourcing` | `:disabled` | events |
| ES-Lazy | `:event_sourcing` | `:lazy` | events |

- **Monitor** appends the event in `after_create`/`after_update`/`after_destroy`,
  inside the write's transaction (not `after_commit`).
- **Hijack and event sourcing** build the event in hooks prepended to
  ActiveRecord's persistence, after the model's `before_*` callbacks.
- **Callback-bypassing writes** (`update_columns`, `update_column`, `touch`,
  `delete`, `update_all`, `delete_all`, `insert_all`, `upsert_all`) on a
  monitored model publish bypass events; with `config.strict_data_access = true`
  they raise instead (except `touch`).
- Each record has its own stream, named `"Model$id"` (for example `"Order$42"`).
- **ES-NoProj** writes no rows; it answers a query exactly from the events or
  raises `Lyra::Projections::UnsupportedQuery`.
- **Switching modes after boot is gated**: `Lyra::ModeTransition.to!` (and
  `config.enable_hijack!`, `enable_monitor!`, `enable_event_sourcing!`) checks
  that rows and events agree before a switch that changes the authoritative
  store, and the engine refuses to boot into such a switch without a
  certificate from `rake lyra:mode:check`. See
  [Switching Modes](docs/MODE_TRANSITIONS.md).

## Requirements and installation

- Ruby >= 3.4.5, Rails >= 8.0, `rails_event_store` ~> 3.0 (from `lyra.gemspec`).
- PostgreSQL. Lyra depends on the `pg` gem; the advisory locks behind Genesis
  and ES-Lazy, and id reservation in Hijack mode, need PostgreSQL.

The gem names differ from the files to require:

```ruby
# Gemfile
gem "orfeas_lyra", path: "path/to/lyra", require: "lyra"
gem "orfeas_pam_dsl", path: "path/to/lyra/gems/pam_dsl", require: "pam_dsl"          # optional, privacy features
gem "orfeas_petri_flow", path: "path/to/lyra/gems/petri_flow", require: "petri_flow"  # optional, verification
```

Create the event store tables with the RailsEventStore 3 generator
(`bin/rails generate ruby_event_store:active_record:migration`), then add an
initializer. The [Migration Guide](docs/MIGRATION_GUIDE.md) walks through the
whole path from Disabled to event sourcing.

## Features

Beyond the modes above (see the [API Reference](docs/API_REFERENCE.md) for each):

- **Genesis**: rows that predate Lyra get an `Imported` event on first use, or
  ahead of time with `rake lyra:genesis`.
- **Failure policies**: Hijack and event sourcing are fail-closed (the write
  rolls back); Monitor logs and continues, and `rake lyra:repair` brings the
  event log back in line with the tables.
- **DualView**: compare a record's table row with its event-sourced state;
  optionally sampled after commit (`config.dual_view_sample_rate`, off by default).
- **Point-in-time state**: `Lyra.state_at(Model, id, time)` and `Model.as_of(time)`.
- **Privacy** (all opt-in; most need the pam_dsl gem): purpose-bound reads,
  an access log, privacy stamps in event metadata, erasure of one record's
  personal data from its row and its events (`rake lyra:erase`), and retention
  rules (`rake lyra:retention:apply`).
- **Formal verification** (needs petri_flow): generate Petri net workflows
  from Lyra's model mapping and verify them.
- **Dashboard**: `mount Lyra::Engine, at: "/lyra"`. The engine adds no
  authentication; wrap the mount in your own constraint.

---

## Example application

`examples/blog_app/` is a small blog (users, posts, comments) using
`monitor_with_lyra`; see its [README](examples/blog_app/README.md). Its
`Gemfile` has not been updated for the current requirements (it pins Rails 7.1
and `rails_event_store` 2.14, which Lyra no longer accepts), so it does not
install as is; read it as an illustration. The files
[`examples/usage_examples.rb`](examples/usage_examples.rb),
[`examples/privacy_examples.rb`](examples/privacy_examples.rb) and
[`examples/privacy_policy_usage.rb`](examples/privacy_policy_usage.rb) show
individual calls.

---

## Benefits

### For Research
- **Orthogonal Analysis**: Compare static vs. dynamic views of system state
- **Behavioral Analysis**: Understand system evolution over time
- **Migration Patterns**: Study CRUD-to-ES transformation strategies
- **Formal Verification**: Check the CRUD-to-event mapping with Petri net models (petri_flow)
- **Privacy Compliance**: Research privacy-preserving event sourcing patterns

### For Development
- **Gradual Migration**: Move to event sourcing one checked mode switch at a time
- **Audit Trail**: History of every write to a monitored model that goes through ActiveRecord
- **Temporal Queries**: Query state at a point in time
- **Debugging**: Replay events to understand issues
- **CQRS Support**: Commands and aggregates alongside the projected tables

### For Operations
- **Few code changes**: A model is monitored by one line or by naming it in the initializer; controllers and queries stay as they are (see [Adopting Lyra](docs/ADOPTION.md) for what this costs)
- **Rollback**: Every mode can be switched back to the previous one
- **Monitoring**: Compare table and event-sourced state (DualView)
- **Validation**: A switch that makes the events authoritative is checked first
- **Performance Analysis**: Measure overhead before committing

---

## Documentation

### Core Documentation
- **[Getting Started](docs/GETTING_STARTED.md)** - Install, monitor one model, and check its events
- **[Migration Guide](docs/MIGRATION_GUIDE.md)** - Installation and the step-by-step move from CRUD to event sourcing
- **[API Reference](docs/API_REFERENCE.md)** - Configuration options, methods, rake tasks and errors
- **[Architecture Overview](docs/ARCHITECTURE.md)** - System design and components
- **[Switching Modes](docs/MODE_TRANSITIONS.md)** - Who holds the mode, and how to switch safely (the deploy-time rule)
- **[Adopting Lyra](docs/ADOPTION.md)** - What "non-intrusive" means, the costs, and a checklist for a new codebase
- **[Performance](docs/PERFORMANCE.md)** - Overhead per mode, from the July 2026 baseline, which is being re-measured
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** - Common problems
- **[Monorepo Structure](docs/MONOREPO.md)** - Repository organization
- **[Changelog](CHANGELOG.md)**

### Theoretical Foundation
- **[ORFEAS Framework Overview](docs/ORFEAS_FRAMEWORK_OVERVIEW.md)** - Complete framework description
- **[Petri Nets Model](gems/petri_flow/docs/THEORETICAL_MODEL_PETRI_NETS.md)** - P/T nets for verification, CPNs for data modeling
- **[Matrix Analysis Model](gems/petri_flow/docs/THEORETICAL_MODEL_MATRICES.md)** - Linear algebra approach

### Privacy & Compliance
- **[PAM DSL Integration](gems/pam_dsl/docs/PAM_DSL_INTEGRATION.md)** - Privacy policy DSL guide
- **[Privacy Compliance](docs/PRIVACY_COMPLIANCE.md)** - GDPR compliance details

### Components
- **[PetriFlow Export](gems/petri_flow/docs/PETRIFLOW_EXPORT.md)** - Export formats and integration
- **[PetriFlow Gem](gems/petri_flow/README.md)** - Petri net library documentation
- **[PAM DSL Gem](gems/pam_dsl/README.md)** - Privacy DSL documentation

### Development
- **[Testing Guide](docs/TESTING.md)** - Testing strategy and setup

---

## Research Foundation

ORFEAS and Lyra are grounded in peer-reviewed research:

### Published Papers

**Pantelelis, M., & Kalloniatis, C. (2022).** *Mapping CRUD to Events: Towards an object to event-sourcing framework.*
26th Pan-Hellenic Conference on Informatics (PCI 2022).
DOI: [10.1145/3575879.3576006](https://doi.org/10.1145/3575879.3576006)

### Research Areas

- **Event Sourcing Patterns**: Formal models for CRUD-to-event transformation
- **Privacy-Preserving Systems**: GDPR compliance in event-driven architectures
- **Petri Net Theory**: P/T nets for workflow verification, CPNs for advanced data modeling
- **Matrix Analysis**: Linear algebra approaches to causation and lineage
- **Software Architecture**: Gradual migration strategies for legacy systems

---

## Development Methodology

This proof-of-concept was developed using **AI-assisted code generation** to accelerate implementation while maintaining focus on theoretical contributions.

### AI Tools Used

- **Claude Code** (Anthropic's agentic coding tool) - Primary development assistant for code implementation, testing, and documentation
- **Claude** (Anthropic) - For architectural discussions and design decisions

**Important**: All architectural decisions, design patterns, and theoretical foundations were specified by the researcher. AI assistance was used for:
- Code implementation following defined specifications
- Test generation based on requirements
- Documentation formatting and organization
- Code review and refactoring

This methodology enabled rapid prototyping while ensuring the theoretical rigor required for academic research.

---

## Contributing

Lyra is research software for the ORFEAS framework. Contributions and feedback are welcome!

### Ways to Contribute

- **Bug Reports**: Submit issues on GitHub
- **Feature Requests**: Suggest improvements or new features
- **Research Collaboration**: Collaborate on research extensions
- **Documentation**: Improve documentation and examples
- **Testing**: Add test cases and improve coverage

### Development Setup

```bash
# Clone the repository
git clone https://github.com/mpantel/lyra-engine.git lyra
cd lyra

# Install dependencies
bundle install

# The engine's tests need PostgreSQL on localhost:5433 (user and password
# "postgres", database lyra_test; see test/dummy/config/database.yml).
# docker-compose.yml provides one:
bundle exec rake docker:start
docker exec lyra_postgres createdb -U postgres lyra_test

# Run the engine's tests, then pam_dsl's and petri_flow's
bundle exec rake test:all

# Build the gems
bundle exec rake build
(cd gems/pam_dsl && bundle exec rake build)
(cd gems/petri_flow && bundle exec rake build)
```

---

## Citation

If you use this software in academic research, please cite:

### Software Citation

```bibtex
@software{lyra2026,
  title={Lyra: CRUD to Event Sourcing Transformation Engine},
  author={Pantelelis, Michail},
  year={2026},
  note={Part of ORFEAS Framework},
  url={https://github.com/mpantel/lyra-engine}
}
```

### Research Paper Citation

```bibtex
@inproceedings{pantelelis2022mapping,
  title={Mapping CRUD to Events: Towards an object to event-sourcing framework},
  author={Pantelelis, Michail and Kalloniatis, Christos},
  booktitle={26th Pan-Hellenic Conference on Informatics (PCI 2022)},
  year={2022},
  doi={10.1145/3575879.3576006}
}
```

### References

- [Rails Event Store](https://railseventstore.org/) - Event Store implementation
- [Event Sourcing Pattern](https://martinfowler.com/eaaDev/EventSourcing.html) - Martin Fowler
- [CQRS](https://martinfowler.com/bliki/CQRS.html) - Command Query Responsibility Segregation
- [Petri Net Theory](http://www.informatik.uni-hamburg.de/TGI/PetriNets/) - Formal foundation
- [GDPR Compliance](https://gdpr.eu/) - Privacy regulation

---

## Support

For questions, issues, and collaboration:

- **Email**: mpantel@aegean.gr
- **GitHub Issues**: [Repository Issues](https://github.com/mpantel/lyra-engine/issues)
- **Institution**: University of the Aegean, Department of Information and Communication Systems Engineering

---

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

**Built with Ruby, Petri Net Theory, and Formal Methods**
**Part of the ORFEAS PhD Research Project**
