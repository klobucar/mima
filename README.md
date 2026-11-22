# mima

<p align="center">
  <img src="assets/mima.png" alt="mima" width="520" />
</p>

**A Keychain-backed environment manager for macOS.** Group API keys, database URLs, and other secrets; inject one group into a child process with a single Touch ID prompt. Useful today for scoping what an AI coding agent can see, or running commands with project-specific credentials. On the roadmap: a shell hook with per-project `.mima.yaml` discovery, at which point mima becomes a full `direnv` replacement with Keychain-backed values.

---

## Status

Alpha. What works today:

- `mima secret` — add / list / get / remove secrets in the macOS Keychain with a `.userPresence` ACL
- `mima group` — map environment-variable names to secret names, organised into groups (`~/.mima.yaml`)
- `mima run <group> -- cmd` — one Touch ID unlocks the whole group; secrets are injected into the child via `execve`, never into the parent `environ`
- `mima run --scrub <group> -- cmd` — same, but the child gets *only* the group plus a minimal safelist (`PATH`, `HOME`, `TERM`, …), not your whole environment
- `mima env <group>` — print shell `export` lines for `eval "$(...)"` in an interactive shell
- `mima doctor` — verify the binary is signed for Touch ID, that protected storage works, and list unprotected secrets and broken group mappings

Not yet (see [Roadmap](#roadmap)):

- Shell hook (`mima hook zsh|bash|fish`) with per-project `.mima.yaml` discovery — three loading modes (wrapper / public-env / compat), see [Threat model](#threat-model)
- Session agent so Touch ID amortises across a shell session instead of firing on every prompt
- `direnv allow`-style trust model, flake integration, `.env` loader, `PATH_add`

## Agent sandboxing

This is mima's sharpest use today. Local coding agents — Claude Code, aider, codex, cursor — run under your shell and inherit your full `environ` by default. If you've ever `export`ed a prod AWS key, a personal GitHub token, or a billing-capable Stripe key, the agent can see all of it, and it can shell out. mima's per-group model plus `--scrub` is the intervention: each agent gets one group containing only what it needs, and nothing else from your shell.

```bash
mima group link agent-claude GITHUB_TOKEN      gh-agent-readonly
mima group link agent-claude ANTHROPIC_API_KEY anthropic-key
mima run --scrub agent-claude -- claude-code

mima group link agent-aider OPENAI_API_KEY     openai-key
mima run --scrub agent-aider -- aider
```

Without `--scrub`, the agent also inherits your full shell environment — the group is added on top. Always pass `--scrub` for agents. If an agent needs one more variable from your shell, pass it explicitly with `--keep VAR`.

Delete the group when you're done with a project; the underlying secret stays in the Keychain for reuse elsewhere.

> **Why not `env -i`?**
> `env -i cmd` scrubs the inherited env — correct, but it doesn't give you any way to re-inject the scoped values the agent actually needs. mima is the "where do those values come from" half: Keychain-stored, biometric-gated, declared as a group. `mima run --scrub` combines both: strip the parent env, inject only the group, keep a minimal safelist like `PATH`, `HOME`, `TERM`.

## Install

```bash
git clone https://github.com/klobucar/mima.git
cd mima
make install SIGNING_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
mima doctor        # confirms Touch ID protection is actually in effect
```

For Touch ID protection you need two things from a **paid** Apple Developer account. The free tier is not enough.

- **An "Apple Development" signing identity.** List yours with `security find-identity -v -p codesigning`. The value in parentheses is a per-person ID, not your team ID. The build reads the team ID from the certificate itself.
- **A macOS development provisioning profile for your team.** The easiest way to get one: in Xcode, build any macOS app target once with your team selected and automatic signing on. Xcode then writes a `Mac Team Provisioning Profile: *` into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`, and `make` finds it automatically. You can also pass `PROFILE=/path/to/profile.provisionprofile` explicitly.

`make install` with an identity builds `Mima.app` into `/usr/local/libexec/mima/` and symlinks `/usr/local/bin/mima` to it. The app bundle is required: only a bundle can carry the provisioning profile. `scripts/sign.sh` explains the details. Set `PREFIX=` to install elsewhere.

<details>
<summary>Why the paid account is required for Touch ID</summary>

Apple gates the biometric / `.userPresence` Keychain ACL behind the $99/year Developer Program. Three things have to line up for a `mima secret get` to fire a Touch ID prompt:

1. **A stable Team ID on the binary.** The Keychain records the calling binary's Team ID + bundle identifier as part of the ACL identity. Ad-hoc-signed binaries have no Team ID — the OS treats every rebuild as a different identity, so a `.userPresence`-gated item written by one build can't be read by the next, and biometric `LAContext` evaluation refuses to bind to ad-hoc code paths at all.
2. **The keychain-access-groups entitlement, authorized by a provisioning profile.** `.userPresence` items live in the data protection Keychain, which requires this entitlement. On macOS it is *restricted*: AMFI kills, at launch, any binary that claims it without an embedded provisioning profile authorizing it. That includes ad-hoc and Developer ID-signed binaries. A bare command-line binary can't embed a profile, so mima ships as a minimal app bundle.
3. **A signing identity issued to a Developer Program member.** Apple issues "Apple Development" / "Apple Distribution" certificates only to enrolled members. The free tier you get from signing in with an Apple ID is a **"Personal Team"** identity — sufficient to sideload an app to a device you own, but explicitly not allowed to enable Keychain Sharing, App Groups, or anything that touches the LocalAuthentication framework. Xcode will surface a `requires a development team with the Apple Developer Program` error if you try.

The reason Apple draws the line there: every binary that can pop a system biometric prompt is a phishing vector. Tying that capability to a verified, revocable developer identity means a compromised cert can be killed centrally — Apple revokes the cert, the binary stops working everywhere overnight. Personal Teams have no equivalent revocation path.

References: [Code Signing in Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) · [`SecAccessControlCreateWithFlags`](https://developer.apple.com/documentation/security/1394452-secaccesscontrolcreatewithflags) · [Keychain Services Access Control](https://developer.apple.com/documentation/security/restricting_keychain_item_accessibility)

</details>

> **Without a paid signing identity:** plain `make install` signs ad-hoc with no entitlements, and secrets go into the legacy login Keychain without the `.userPresence` ACL. `mima secret add` says so each time, and `mima doctor` reports it. Values stay encrypted at rest, but **the Touch ID gate that anchors the threat model goes away** — any process running as you can read them by calling `SecItemCopyMatching` against an unlocked login Keychain. mima still beats a plaintext `.envrc` (an attacker needs to know mima's service name and call the Keychain API), but the headline biometric-gated property in the [Threat model](#threat-model) is not in effect on this install.
>
> **Upgrading from an ad-hoc install:** a signed build won't read secrets stored without protection. It reports them as unprotected instead of silently accepting an item that any process could have planted. `mima doctor` lists them. Re-add each one with `mima secret remove <name>` and then `mima secret add <name>`.

## Quick start

```bash
# Stash secrets in the Keychain
mima secret add openai-key          # prompts for value securely
mima secret add anthropic-key

# Map env-var names to secret names, under a group
mima group link agent OPENAI_API_KEY openai-key
mima group link agent ANTHROPIC_API_KEY anthropic-key

# Run a command with just that group's env
mima run --scrub agent -- claude-code
```

One Touch ID prompt. `claude-code` starts with `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` set. With `--scrub`, nothing else from your shell leaks in beyond a minimal safelist; without it, the child inherits your full environment plus the group. Either way, your parent shell's `environ` is never touched.

## Commands

### `mima secret`

```bash
mima secret add <name>              # prompt securely (getpass)
mima secret add <name> <value>      # inline — avoid, goes into shell history
mima secret rm <name>
mima secret list                    # names only, no values
mima secret get <name>              # print value; warns to stderr
mima secret get <name> --export     # print `export NAME=VALUE`
```

### `mima group`

```bash
mima group link <group> <ENV_VAR> <secret-name>
mima group list
```

Mappings are stored in `~/.mima.yaml`, written atomically:

```yaml
groups:
  agent:
    OPENAI_API_KEY: openai-key
    ANTHROPIC_API_KEY: anthropic-key
  dev:
    DATABASE_URL: dev-db
    STRIPE_KEY: stripe-test
```

### `mima run`

```bash
mima run <group> -- <command> [args...]
mima run --scrub <group> -- <command> [args...]
mima run --scrub --keep SSH_AUTH_SOCK <group> -- <command> [args...]
```

Unlocks the group's secrets behind a single `LAContext`, then `execve`s the command with an explicit envp. The parent `mima` process never calls `setenv`.

- **Default:** the envp is your current env plus the group's values (a group value wins over a same-named shell variable).
- **`--scrub`:** the envp is *only* the group's values plus `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TERM`, `TMPDIR`, `LANG`, `TZ`, and `LC_*`. `TMPDIR` stays because macOS points it at a per-user directory; without it, tools fall back to the shared `/tmp`. `SSH_AUTH_SOCK` is deliberately excluded — it lets the child authenticate and sign as you over SSH.
- **`--keep VAR`** (repeatable, requires `--scrub`): pass one more variable through.

Options go before the group name. Everything after the group belongs to the command, so `mima run g --scrub -- cmd` is rejected with an error rather than silently running unscrubbed.

### `mima env`

```bash
eval "$(mima env <group>)"
```

Prints shell `export` lines. Less private than `mima run` because values land in your interactive shell, but useful when you need secrets for multiple ad-hoc commands. Output is POSIX-single-quote-escaped, so apostrophes and shell metacharacters cannot break the quoting.

### `mima doctor`

```bash
mima doctor
```

Checks the binary's team signature and `keychain-access-groups` entitlement. It then stores and deletes a throwaway Touch ID-protected item, with no read and so no prompt. It lists any secrets stored without protection and any group mappings that point at missing secrets. It exits non-zero if anything is wrong.

## Other use cases

### Project-scoped secrets without a plaintext `.envrc`

Instead of:

```bash
# .envrc (gitignored, hopefully)
export STRIPE_KEY="sk_live_..."
export DATABASE_URL="postgres://..."
```

…store values once in the Keychain and reference them by name in `~/.mima.yaml`:

```yaml
groups:
  my-saas:
    STRIPE_KEY: stripe-prod
    DATABASE_URL: saas-db-url
```

For now, run commands via `mima run my-saas -- cmd`. Once the shell hook ships, the group will load automatically when you `cd` into a project with a matching `.mima.yaml`.

### Swap environments without reloading your shell

```bash
mima run staging -- ./deploy.sh
mima run prod    -- ./deploy.sh
```

## Compared to

mima isn't strictly better than any of these — pick the one whose tradeoffs match your workflow.

- **1Password CLI (`op run`).** The closest competitor. `op run --env-file=.env -- cmd` injects values per invocation and is biometric-gated once `op` is authenticated. Choose `op` if you need shared team vaults, audit logs, RBAC, or non-macOS support. Choose mima if you want local-only storage, no subscription, no network round-trip per invocation, and a free baseline. Roughly: 1Password is to your team what the Keychain is to your machine.
- **direnv.** direnv exports values into your interactive shell's `environ` on `cd`. Every subsequent process inherits them — including `npm install` postinstalls, the precise transitive surface that supply-chain stealers exploit. `mima run` is process-scoped: secrets only land in the env of the command you named. Once the shell hook lands, wrapper mode gives you direnv-shaped ergonomics with the process scoping intact.
- **direnv + `op run`.** A common compromise: `.envrc` calls `op run` to fetch values, scoped to the current shell. Better than plaintext direnv, but you're back to shell-wide `environ` exposure for any tool that auto-runs on `cd`. mima's wrapper mode is the same idea minus the shell-wide step.
- **aws-vault.** Same shape — Keychain-backed, biometric-gated, exec-only — but AWS-specific. mima generalises the pattern to any env var.
- **sops / age.** File-encrypted at rest, decrypted on demand. Strong for team config in a repo and for CI; awkward for personal interactive use because every command needs the decryption step. mima trades portability for ergonomics on a single machine.
- **Plain `.env` / `.envrc`.** Plaintext on disk, readable by any process running as you. Exactly the credential-stealer payload. Don't.

## Security model

- Secrets are stored via `SecItemAdd` with `kSecAttrAccessControl = .userPresence`, so retrieval requires biometric or passcode authentication.
- One `LAContext` is reused for batch reads in `mima run`, so a single authorisation unlocks N secrets.
- `mima run` uses `execve` with an explicit envp. The parent process never calls `setenv`, so secrets do not appear in the parent's `environ`.
- `mima env` prints secrets to stdout and is inherently less private — use it deliberately. Output is POSIX-escaped against quoting attacks.
- mima cannot protect against a malicious child process. Once the child has the env var, it has the env var. Scope groups narrowly; prefer `mima run` over `mima env` when you can.
- mima does not manage SSH keys. Use [Paprika](https://github.com/klobucar/paprika) or an equivalent Secure-Enclave SSH agent for those. mima's scope is environment variables only.

## Threat model

mima's design is shaped by the class of attacks that dominates 2023–present: **supply-chain credential stealers**. Shai-Hulud (npm, 2025–ongoing), recurring PyPI token-stealer waves, compromised IDE extensions, malicious CLI tools from `curl | sh` installers, and prompt-injected agent commands. They all share a pattern: attacker code executes *as you* during a routine action (package install, extension load, tool invocation), and the payload almost always lifts every credential it can read — env vars, dotfiles, `~/.aws/credentials`, `~/.npmrc`, the lot — and posts them to a webhook before you've noticed. macOS's permission layer doesn't stop a process running as your user from reading anything else you can read. What saves you is what isn't accessible — values that aren't at rest, and values gated behind a prompt you'd notice.

### What mima defends against

- **Plaintext credential files.** `.env` / `.envrc` / `~/.aws/credentials` / `~/.npmrc` are readable by any process running as you, and the common scraper pattern is to read them directly. mima stores values in the Keychain — encrypted at rest, opaque to a quick `cat`. With a paid Apple Developer signing identity ([see Install](#install)), retrieval is also gated by `.userPresence`: an attacker reading values triggers a Touch ID prompt out of nowhere, which is extremely conspicuous.
- **Globally-exported shell env.** If `.zshenv` runs `export STRIPE_KEY=…`, every process you launch — including every transitive postinstall script — inherits it forever. `mima run` scopes values to the specific child process you named; they never enter the parent shell's `environ`.
- **Secrets in shell history.** `mima secret add` uses `getpass`, never command-line arguments. Values never land in `.zsh_history`.
- **Over-broad agent access.** Coding agents inherit your full shell env by default. `mima run --scrub agent-claude -- claude-code` hands the agent only the variables you explicitly grouped for it, plus a minimal safelist (`PATH`, `HOME`, `TERM`, …). Without `--scrub` the agent inherits your full shell environment, so `--scrub` is the agent-sandboxing mode.

### What mima does not defend against

- **Malicious children leaking the env they received.** Once the child has the variable, it can send it anywhere. Defense is narrow groups + sandboxing (devcontainer, firejail, macOS app sandbox).
- **Deceptive Touch ID prompts.** An attacker who can invoke the mima binary can trigger a legitimate biometric prompt. User vigilance is the only thing stopping a reflexive approval.
- **Shell-level compromise.** If your `.zshrc`, a shell plugin, or a supply-chain-compromised tool has injected code into your shell, mima runs inside that trust boundary and can't help.
- **Session agent TTL window.** When the session agent ships, unlocked values will sit in memory for a configurable interval. During that window, a supply-chain attacker running as you can read them without triggering a biometric prompt — the same class of risk `ssh-agent` and `op` accept. Short TTLs mitigate; they do not eliminate.
- **`mima env` + `eval`.** After you eval the output, values are in the shell `environ` for the rest of the session. Same threat surface as plain `export`. Use deliberately.

### Shell-loading modes

Supply-chain attacks shape how the shell hook works. A direnv-style auto-export on every `cd` would defeat mima's best property — putting group secrets into your shell `environ` so that any subsequent `npm install` or `pip install` inherits them. To keep secrets process-scoped by default while still offering direnv ergonomics, the hook supports three modes:

- **Wrapper mode (default).** `mima hook zsh` defines per-group shell functions when you enter a project. `dev` and `agent-claude` become functions that expand to `mima run <group> -- "$@"`. Every invocation is still `execve`-scoped; secrets never enter the shell `environ`. Touch ID fires per-command — amortised by the session agent once that lands.
- **Public-env mode.** `.mima.yaml` may declare an `env:` section for non-secret values (PATH additions, tool versions, nix/flake outputs). The hook auto-exports that section on `cd`; `groups:` (Keychain-backed secrets) stay behind `mima run`. Mirrors the nix-direnv pattern.
- **Compat mode (opt-in).** `auto_export: true` in `.mima.yaml` restores direnv-classic UX: groups auto-export on `cd`, unset on leave. Strictly weaker than wrapper mode against supply-chain attacks — any subsequent process in the shell inherits the secrets — but still an improvement over globally-exported `.zshenv`, because blast radius is scoped to one project at a time. Opt-in because the tradeoff should be conscious.

### Out of scope

mima raises the cost of credential theft; it doesn't prevent it. Not in scope: `curl | sh` review, phishing, MDM compromise, device theft with a weak passcode, or a persistent determined adversary with ongoing local code execution.

## Roadmap

Short version below; [`ROADMAP.md`](ROADMAP.md) has rationale, open questions, and a "considered, not planned" section.

1. **Shell hook + directory discovery.** `mima hook zsh` emits a precmd that discovers the nearest `.mima.yaml` by walking upward from `pwd`. Three loading modes:
   - **Wrapper mode** (default) — define per-group shell functions that expand to `mima run <group> -- "$@"`. Secrets stay process-scoped.
   - **Public-env mode** — auto-export a declared non-secret `env:` section; groups stay behind `mima run`.
   - **Compat mode** — auto-export groups on `cd` / unset on leave, direnv-classic. Opt-in via `auto_export: true` in `.mima.yaml`.

   See [Threat model](#threat-model) for why wrapper mode is the default.
2. **Trust model.** `mima allow` / `mima deny` stores a content hash per config file, refusing to auto-load untrusted ones — same idea as `direnv allow`.
3. **Session agent.** A small launchd daemon holds unlocked values in memory keyed to a shell session so Touch ID amortises across a work session rather than firing on every `cd`.
4. **Nix / flake integration.** `use flake` shells out to `nix print-dev-env --json`, caches by flake-lock hash, merges into the exported env.
5. **Dotenv + `PATH_add`.** Cover the direnv use cases that don't need Keychain.

## Related

**Paprika** ([github.com/klobucar/paprika](https://github.com/klobucar/paprika)) is a Secure-Enclave SSH agent by the same author. Paprika handles SSH identity via `SSH_AUTH_SOCK`; mima handles everything else your shell exports. Together they cover the Touch-ID-gated-secrets surface of a dev shell, but either works standalone.

## License

MIT
