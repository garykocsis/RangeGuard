# RangeGuard – Project Setup

## Overview

This document captures the initial setup and foundational decisions for the RangeGuard project, including repository creation, development environment configuration, and early structural choices.

It serves as both:

- a record of how the project was initialized, and
- a reference point for how the development environment and workflow evolved over time.

The goal is to establish a clean, production-grade foundation suitable for building a DeFi protocol using modern Solidity tooling.

## Project Intent

RangeGuard is being developed as a DeFi protocol with an emphasis on production-level engineering practices, including security, uniswap v4 hook architecture, and auditability.

The project is designed to demonstrate not only smart contract implementation, but also engineering process, system design, and development discipline.

It is will be my entry for the hookathon project in the Uniswap Hook Incubator (UHI) program.

---

## Repository Creation

The repository was created using the GitHub CLI to align with a terminal-first development workflow:

```bash
gh repo create RangeGuard --public --clone
cd RangeGuard
```

### Rationale

- Using the CLI mirrors real-world engineering workflows
- Ensures immediate local ↔ remote synchronization
- Avoids manual setup inconsistencies from UI-based initialization

---

## Git Configuration and First Commit Strategy

The project was initialized with a clean commit history in mind.

Key decisions:

- No default README, license, or boilerplate files added at repo creation
- No example contracts retained from tooling scaffolds
- First commit represents an intentional project baseline

### Initial Commit

```bash
forge init --no-git --force
```

The default example contracts (Counter) were removed to avoid unnecessary boilerplate and to ensure all code in the repository is intentional and relevant.

---

## Development Framework

The project uses Foundry as the primary development framework.

### Why Foundry

- Fast compile and test cycle
- Native support for fuzzing and invariant testing
- Strong suitability for protocol-level smart contract development
- Widely adopted in modern DeFi engineering workflows

---

## Project Structure

The repository follows a modular structure to support scalability and auditability:

```text
src/
test/
script/
lib/
/docs
```

Additional sub-structure will be introduced as the protocol architecture evolves.

### Notes

- `lib/forge-std` is included as a dependency and contains testing utilities
- Project-specific code will reside exclusively in `src/`

---

## Dependency Management

Dependencies are managed via Foundry's `lib/` directory.

Currently included:

- forge-std (standard testing library)

---

## SSH and GitHub Configuration

The development environment uses SSH-based authentication for interacting with GitHub.

### Setup Summary

- An SSH key was generated and added to the GitHub account
- The local environment was configured to use SSH for repository access
- Repository remotes are configured using SSH URLs

### Notes

SSH authentication was chosen over HTTPS to:

- Avoid repeated credential prompts
- Provide a more seamless developer experience
- Align with standard workflows used in professional engineering environments

During setup, care was taken to ensure that the correct SSH identity was used for repository access, as misconfigured SSH keys can lead to authentication and permission issues when pushing to remote repositories.

---

## Notes on Git Behavior

Git does not track empty directories. Placeholder `.gitkeep` files were added to preserve the intended project structure until files are introduced.

---

## Next Steps

- Define protocol architecture
- Introduce core modules and interfaces
- Begin implementation of Uniswap v4 hook integrations
- Establish testing strategy (unit, fuzz, invariant)

---
