# Contributing to Gaekju

Thank you for considering contributing to Gaekju. This document explains the process for contributing to the project and what we expect from contributors.

## Prerequisites

You'll need the following tools installed:

- **Foundry** (forge, cast, anvil) — `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- **Rust** 1.82+ — `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **Node.js** 20+ — for tooling scripts and ABI generation
- **PostgreSQL** 15+ — for the indexer database
- **Git** with GPG signing configured (recommended)

Verify your setup:

```bash
forge --version    # foundry
cargo --version    # rust 1.82+
node --version     # v20+
psql --version     # 15+
```

## Local Development Setup

```bash
# Clone the repo
git clone https://github.com/gaekju/gaekju.git
cd gaekju

# Install Solidity dependencies
cd contracts
forge install

# Build contracts
forge build

# Run a local Anvil node (separate terminal)
anvil

# Build Rust workspace
cd ../crates
cargo build

# Set up the indexer database
createdb gaekju_dev
cargo run -p gaekju-indexer -- migrate
```

## Code Style

### Solidity

- Format with `forge fmt` before committing. The CI will reject unformatted code.
- Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html).
- All internal accounting uses 18-decimal fixed-point. Never mix decimal scales.
- Use NatSpec comments (`///`) for all public and external functions.
- Keep contracts focused: one responsibility per contract.

### Rust

- Run `cargo fmt` and `cargo clippy -- -D warnings` before committing.
- No `unwrap()` in production code. Use proper error types.
- Prefer explicit types over long inference chains.
- Use `tracing` for logging, not `println!` or `log`.

### General

- No trailing whitespace.
- Files end with a single newline.
- Use descriptive variable names. Abbreviations are fine in math-heavy code when documented.

## Testing

### Solidity

```bash
cd contracts

# Unit tests
forge test

# Run with verbosity for debugging
forge test -vvv

# Run a specific test
forge test --match-test testPlaceAndMatchOrder

# Fuzz tests (longer run)
forge test --match-path test/fuzz/ --fuzz-runs 10000

# Gas snapshots
forge snapshot
```

### Rust

```bash
cd crates

# All tests
cargo test

# Specific crate
cargo test -p gaekju-keeper

# With output
cargo test -- --nocapture
```

### Integration Tests

Integration tests run a full deposit-place-match-fill cycle on a local Anvil fork:

```bash
cd contracts
forge test --match-path test/integration/
```

## Pull Request Process

1. **Branch from `main`.** Use a descriptive branch name: `feat/funding-rate`, `fix/margin-check-overflow`, `docs/adr-0012`.

2. **Keep PRs focused.** One feature or fix per PR. If your change touches more than 5 files, consider splitting it.

3. **Write tests.** Every new feature needs tests. Every bug fix needs a regression test that would have caught the bug.

4. **Update documentation.** If you change behavior, update the relevant docs. This includes NatSpec comments, ADRs, and the changelog.

5. **Open a draft PR early** if you want feedback on direction before completing the work.

6. **Request review** when all checks pass. At least one maintainer approval is required.

7. **Squash and merge** is the default merge strategy.

## Commit Message Convention

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:**
- `feat` — new feature
- `fix` — bug fix
- `refactor` — code change that neither fixes a bug nor adds a feature
- `test` — adding or updating tests
- `docs` — documentation only
- `perf` — performance improvement
- `ci` — CI/CD changes
- `chore` — maintenance tasks

**Scopes:** `contracts`, `indexer`, `keeper`, `api`, `sdk`, `cli`, `docs`

**Examples:**
```
feat(contracts): add post-only order flag to OrderBook
fix(keeper): handle stale Pyth price in liquidation loop
docs: add ADR-0012 for cross-margin design
test(contracts): fuzz test for PackedOrder packing roundtrip
```

## Architecture Decision Records (ADRs)

Significant architectural changes require an ADR before implementation. This includes:

- New contract designs or major refactors
- Changes to the margin, liquidation, or funding models
- New external dependencies or integrations
- Changes to the data model or storage layout

### ADR Process

1. Copy the template from `docs/adr/README.md`.
2. Number it sequentially (e.g., `0012-your-decision.md`).
3. Fill in Context, Decision, Consequences, and Alternatives Considered.
4. Open a PR with just the ADR. Get approval before implementing.
5. Reference the ADR in your implementation PR.

## Questions?

Open a [discussion](https://github.com/gaekju/gaekju/discussions) or reach out to the maintainers.
