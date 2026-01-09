# Testing Guide for Lyra Monorepo

This document describes the automated testing setup for Lyra and its component gems using Minitest.

## Overview

The monorepo contains three testable components:

1. **Lyra** - Main Rails engine for CRUD to Event Sourcing transformation
2. **PAM DSL** - Privacy Attribute Matrix DSL gem
3. **PetriFlow** - Petri Net and Matrix Analysis gem

All components use **Minitest** as the testing framework with the following gems:
- `minitest` - Core testing framework
- `minitest-reporters` - Beautiful test output and JUnit XML reports
- `mocha` - Mocking and stubbing (Lyra only)

## Running Tests

### Run All Tests

To run tests for all components:

```bash
# Using rake
rake test:all

# Using the test runner script
bin/test
```

### Run Tests for Individual Components

**Lyra (main tool):**
```bash
rake test
# or
bundle exec rake test
```

**PAM DSL gem:**
```bash
cd gems/pam_dsl
rake test
```

**PetriFlow gem:**
```bash
cd gems/petri_flow
rake test
```

### Run Lyra 6-Mode Test Suite

Lyra supports 6 operational configurations. The testbed includes a comprehensive test runner that validates all modes:

```bash
cd examples/aegean_epay_testbed
rake lyra:test:all_modes
```

#### The 6 Lyra Modes

| Mode | LYRA_MODE | LYRA_PROJECTION_MODE | Description |
|------|-----------|---------------------|-------------|
| 1 | `disabled` | - | Lyra disabled, standard Rails CRUD |
| 2 | `monitor` | - | Log events, no behavior change |
| 3 | `hijack` | - | Route CRUD through event sourcing |
| 4 | `event_sourcing` | `sync` | Full ES with synchronous projections |
| 5 | `event_sourcing` | `async` | Full ES with background projections |
| 6 | `event_sourcing` | `disabled` | Pure CQRS, reads from cache |

#### Test Output

```
================================================================================
 LYRA TEST SUITE - ALL MODES
 Started: 2025-12-31 14:30:00
================================================================================

[1/6] Running: Lyra Disabled
------------------------------------------------------------
✓ 523 tests, 1189 assertions, 0 failures, 0 errors, 0 skips (15.2s)

[2/6] Running: Monitor Mode
...

================================================================================
 COMPREHENSIVE TEST REPORT
================================================================================

## Results by Configuration

| Configuration                       | Tests  | Assert |  Fail |  Err |  Skip | Status |
|-------------------------------------|--------|--------|-------|------|-------|--------|
| Lyra Disabled                       |    523 |   1189 |     0 |    0 |     0 | PASS   |
| Monitor Mode                        |    523 |   1189 |     0 |    0 |     0 | PASS   |
| Hijack Mode                         |    523 |   1189 |     0 |    0 |     0 | PASS   |
| Event Sourcing (Sync)               |    523 |   1189 |     0 |    0 |     0 | PASS   |
| Event Sourcing (Async)              |    523 |   1189 |     0 |    0 |     0 | PASS   |
| Event Sourcing (No Projections)     |    523 |   1189 |     0 |    0 |     0 | PASS   |

## Summary

Configurations: 6/6 passed
Total Tests:    3138
Total Duration: 95.3s

================================================================================
 ALL CONFIGURATIONS PASSED
================================================================================
```

### Run Specific Test Files

```bash
# Lyra
ruby -Ilib:test test/configuration_test.rb

# PAM DSL
cd gems/pam_dsl
ruby -Ilib:test test/policy_test.rb

# PetriFlow
cd gems/petri_flow
ruby -Ilib:test test/core/net_test.rb
```

### Run Specific Test Methods

```bash
ruby -Ilib:test test/event_test.rb --name test_event_creation
```

## Test Structure

### Directory Layout

```
lyra/
├── test/
│   ├── test_helper.rb              # Main test configuration
│   ├── configuration_test.rb       # Configuration tests
│   ├── event_test.rb               # Event tests
│   ├── event_mapper_test.rb        # Event mapping tests
│   ├── privacy/
│   │   └── pii_detector_test.rb    # Privacy tests
│   ├── projections/
│   │   └── cached_relation_test.rb # CachedRelation tests (37 tests)
│   ├── schema/
│   │   └── event_class_registrar_test.rb # Event class registration tests
│   ├── interceptors/
│   │   └── crud_interceptor_test.rb # Interceptor tests
│   └── integration/
│       ├── event_sourcing_mode_test.rb    # Integration tests (require full Rails)
│       └── event_sourcing_integration_test.rb
│
gems/pam_dsl/
├── test/
│   ├── test_helper.rb              # PAM DSL test configuration
│   ├── policy_test.rb              # Policy DSL tests
│   ├── field_test.rb               # PII field tests
│   ├── consent_test.rb             # Consent management tests
│   ├── retention_test.rb           # Data retention tests
│   └── registry_test.rb            # Policy registry tests
│
gems/petri_flow/
└── test/
    ├── test_helper.rb              # PetriFlow test configuration
    ├── core/
    │   ├── place_test.rb           # Place tests
    │   ├── transition_test.rb      # Transition tests
    │   └── net_test.rb             # Petri net tests
    ├── matrix/
    │   └── analyzer_test.rb        # Matrix analysis tests
    └── simulation/
        └── simulator_test.rb       # Simulation tests
```

### Test Helpers

Each component has a `test_helper.rb` that:
- Configures load paths
- Requires the component library
- Sets up Minitest with reporters
- Configures test output formats

## Test Reports

Tests generate JUnit XML reports suitable for CI/CD integration. Reports are created alongside the spec output and can be consumed by CI tools like:
- GitHub Actions
- Jenkins
- CircleCI
- GitLab CI

## Writing Tests

### Basic Test Structure

```ruby
require "test_helper"

module YourModule
  class YourClassTest < Minitest::Test
    def setup
      # Setup code runs before each test
      @instance = YourClass.new
    end

    def teardown
      # Cleanup code runs after each test
    end

    def test_something
      result = @instance.do_something
      assert_equal expected_value, result
    end

    def test_raises_error
      assert_raises(SomeError) do
        @instance.problematic_method
      end
    end
  end
end
```

### Common Assertions

```ruby
assert(condition)                    # Assert condition is truthy
refute(condition)                    # Assert condition is falsy
assert_equal(expected, actual)       # Assert equality
refute_equal(expected, actual)       # Assert inequality
assert_nil(value)                    # Assert value is nil
refute_nil(value)                    # Assert value is not nil
assert_includes(collection, item)    # Assert collection includes item
assert_raises(Error) { code }        # Assert code raises error
assert_instance_of(Class, object)    # Assert object is instance of class
```

### Using Mocks (Lyra only)

```ruby
def test_with_mock
  mock_object = mock("description")
  mock_object.expects(:method_name).with(arg).returns(value)

  # Test code that uses mock_object

  # Mocha automatically verifies expectations
end

def test_with_stub
  object = SomeClass.new
  object.stubs(:method).returns(stubbed_value)

  # Test code
end
```

## Continuous Integration

The repository includes a GitHub Actions workflow (`.github/workflows/test.yml`) that:
- Runs tests on Ruby 3.4+
- Tests all components
- Uploads test results as artifacts

## Best Practices

1. **Test Names**: Use descriptive test method names starting with `test_`
2. **One Assertion Per Test**: Focus each test on a single behavior
3. **Setup/Teardown**: Use `setup` and `teardown` for common initialization
4. **Test Coverage**: Aim for comprehensive coverage of public APIs
5. **Fast Tests**: Keep tests fast by avoiding I/O when possible
6. **Independent Tests**: Tests should not depend on each other
7. **Descriptive Failures**: Use custom failure messages when helpful

## Troubleshooting

### Tests Not Found

Ensure test files:
- Are in the `test/` directory
- End with `_test.rb`
- Require `test_helper`
- Define test classes inheriting from `Minitest::Test`

### Load Errors

Check that:
- Dependencies are installed: `bundle install`
- Load paths are correct in `test_helper.rb`
- Required files exist

### Permission Errors

Make the test script executable:
```bash
chmod +x bin/test
```

## Adding New Tests

1. Create test file in appropriate directory:
   - `test/` for Lyra
   - `gems/pam_dsl/test/` for PAM DSL
   - `gems/petri_flow/test/` for PetriFlow

2. Follow naming convention: `*_test.rb`

3. Require test helper:
   ```ruby
   require "test_helper"
   ```

4. Define test class:
   ```ruby
   module YourModule
     class YourClassTest < Minitest::Test
       # tests here
     end
   end
   ```

5. Run tests to verify:
   ```bash
   rake test
   ```

## Contributing

When adding new features:
1. Write tests first (TDD)
2. Ensure all tests pass
3. Maintain or improve coverage
4. Follow existing test patterns

For bug fixes:
1. Write a failing test that demonstrates the bug
2. Fix the bug
3. Verify the test now passes
