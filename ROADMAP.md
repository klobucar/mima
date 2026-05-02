# Roadmap

Where mima is and where it's going. The README's [Roadmap section](README.md#roadmap) is the elevator pitch; this file is the working document with rationale, open questions, and explicit non-goals.

## Done

What works today (alpha):

- **`mima secret`** — add / list / get / remove secrets in the macOS Keychain. With a paid Apple Developer identity, items carry a `.userPresence` ACL so retrieval requires Touch ID; without one, ad-hoc signing falls back to encryption-at-rest only (see [Install](README.md#install)).
- **`mima group`** — declare per-project groups in `~/.mima.yaml` mapping environment-variable names to Keychain secret names. Atomic writes.
- **`mima run <group> -- cmd`** — single `LAContext` unlocks the whole group; child is launched via `execve` with an explicit envp, so the parent never calls `setenv` and values never enter its `environ`.
- **`mima env <group>`** — emit POSIX-quoted `export` lines for `eval "$(mima env …)"`. Documented as deliberately less private than `mima run`.
- **CI** — Swift tests, CodeQL, and zizmor run on every push and PR.

## Planned

Roughly in priority order.

### 1. Shell hook + directory discovery

`mima hook zsh|bash|fish` emits a precmd that walks upward from `pwd` for the nearest `.mima.yaml`. Three loading modes shape how secrets reach the shell:

- **Wrapper mode** (default) — declared groups become shell functions that expand to `mima run <group> -- "$@"`. Secrets stay process-scoped per invocation. The threat-model-aware default.
- **Public-env mode** — `.mima.yaml`'s non-secret `env:` section is auto-exported on `cd`; `groups:` (Keychain values) stay behind `mima run`. Mirrors nix-direnv.
- **Compat mode** (opt-in via `auto_export: true`) — direnv-classic. Strictly weaker against supply-chain attacks; opt-in so the tradeoff is conscious.

Open questions:
- Parent/child `.mima.yaml` inheritance — extend or replace?
- Whether to surface an env-delta on `cd`, like direnv does.

### 2. Agent sandbox flag

`mima run --scrub <group> -- cmd` runs the child with **only** the group's env plus a minimal safelist (`PATH`, `HOME`, `TERM`, `USER`, `SHELL`). Companion to [Agent sandboxing](README.md#agent-sandboxing) — strips the parent env in addition to refusing to leak it.

Open questions:
- Default safelist contents (TZ? LANG? LC_*?).

### 3. Trust model

`mima allow` / `mima deny` records a content hash per `.mima.yaml`. Auto-loading refuses any file whose hash isn't in the trust store. Same idea as `direnv allow`. **Required before the shell hook can ship** — without it, `git clone` of a hostile repo turns into code execution on your next `cd`.

Open questions:
- Behaviour on hash mismatch — silent block, or warning that requires `mima allow` to re-bless.
- Where to store the trust file (`~/.mima/trust.yaml` vs. content-hashed dir).

### 4. Session agent

Small launchd daemon holds unlocked group values in memory keyed to a shell session, so one Touch ID covers many `mima run` invocations across that session. Same shape as `ssh-agent` / `op` daemon, with a configurable TTL.

Open questions:
- Default TTL (lean short — `op` defaults to 30min, mima should probably do less).
- Session identity: TTY group, PID tree, or explicit unlock token?
- Memory hygiene: zero on TTL expiry; refuse to swap.

### 5. Nix / flake integration

`use flake` shells out to `nix print-dev-env --json`, caches by `flake.lock` hash, merges into the exported env. Mirrors nix-direnv.

### 6. Dotenv + `PATH_add`

The remaining direnv-shaped niceties: a `.env` loader for non-secret per-project values, `PATH_add` for `<project>/bin`-style PATH munging. Lowest priority — easy to replicate with shell snippets in the meantime.

## Considered, not planned

- **CI runner.** A `mima run` analogue for Linux build runners (env vars or a vault adapter as the backend). Rejected: mima's value props (Touch ID, Keychain, process-scoped envp) all require macOS, and CI environments already have `op run`, `aws-vault exec`, `vault exec`, and native CI secret stores. A small `mima check <group>` preflight (verify every mapped var resolves to *something*, regardless of source) might earn its place; a full runner won't.
- **Non-macOS support.** mima is a thin shell over the macOS Keychain + LocalAuthentication. A Linux equivalent would need a different secret backend (libsecret, `pass`, KWallet) and a different biometric story (fido2, PAM) — that's a different tool with a different threat model. Fork it if you want it.
- **Built-in secret rotation / expiry tracking.** Out of scope. Pair with whatever already tracks key age (1Password Watchtower, GitHub secret scanning, AWS rotation).
- **Vault / 1Password as a backend.** Same reasoning as the CI runner — those tools already exist and are good. mima is the local-Keychain-Touch-ID story, full stop. Use `op run` if you want a hosted vault.

## Maybe — interesting but not committed

Ideas that are speculative; might happen, might not.

- **`mima diff <group>`** — show what differs between two groups, useful when maintaining `dev` / `staging` / `prod`.
- **`mima export <group>`** — emit a portable group file (mappings only, never values) for sharing structure between machines or onboarding teammates. Pairs with a `mima init` that walks the file and prompts for each value.
- **Optional audit log.** Opt-in record of which group was unlocked when, written to `~/.mima/audit.log`. Useful for post-hoc "did anything weird touch my Stripe key today?" review. Off by default because the log itself becomes a target.
