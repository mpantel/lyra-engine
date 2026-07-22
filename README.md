# Lyra

**CRUD to Event Sourcing Transformation Engine**

*Part of the ORFEAS (Object-Relational to Event-Sourcing Architecture) Framework*

### Blog App (Getting Started)

A simpler example for learning Lyra basics is in `examples/blog_app/`:

```bash
cd examples/blog_app
bundle install
rails db:create db:migrate db:seed
rails console
```

[Explore the blog example →](examples/blog_app/README.md)

---

## Benefits

### For Research
- **Orthogonal Analysis**: Compare static vs. dynamic views of system state
- **Behavioral Analysis**: Understand system evolution over time
- **Migration Patterns**: Study CRUD-to-ES transformation strategies
- **Formal Verification**: Prove correctness using Petri net theory
- **Privacy Compliance**: Research privacy-preserving event sourcing patterns

### For Development
- **Zero Downtime Migration**: Gradually transition to event sourcing
- **Audit Trail**: Complete history of all state changes
- **Temporal Queries**: Query state at any point in time
- **Debugging**: Replay events to understand issues
- **CQRS Support**: Natural separation of commands and queries

### For Operations
- **Non-intrusive**: Deploy without code changes
- **Rollback Safety**: Keep CRUD as safety net during transition
- **Real-time Monitoring**: Compare CRUD vs event-sourced state
- **Validation**: Verify event sourcing correctness before full migration
- **Performance Analysis**: Measure overhead before committing

---

## Documentation

### Core Documentation
- **[Getting Started Guide](docs/GETTING_STARTED.md)** - Installation and first steps
- **[Architecture Overview](docs/ARCHITECTURE.md)** - System design and components
- **[Performance](docs/PERFORMANCE.md)** - Measured overhead per mode, and how to pick one
- **[Monorepo Structure](docs/MONOREPO.md)** - Repository organization

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

# Run tests
rake test

# Build gems
cd gems/petri_flow && rake build
cd gems/pam_dsl && rake build
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
