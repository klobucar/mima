# mima

<p align="center">
  <img src="assets/mima-banner.png" alt="MIMA. Split Identity. Keep it real." width="780" />
</p>

<p align="center">
  <a href="https://github.com/klobucar/mima/actions/workflows/swift.yml"><img src="https://github.com/klobucar/mima/actions/workflows/swift.yml/badge.svg" alt="CI status"></a>
  <img src="https://img.shields.io/badge/swift-5.10%2B-orange.svg" alt="Swift 5.10+">
  <img src="https://img.shields.io/badge/macOS-12%2B-blue.svg" alt="macOS 12+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

**A Keychain-backed environment manager for macOS.** Store API keys, database URLs, and other secrets in the macOS Keychain. Give a command the variables it needs without exporting them into your shell. A properly signed build can unlock a group with one Touch ID or login password prompt.

[Install](#install) · [Quick start](#quick-start) · [Use with coding agents](#use-with-coding-agents) · [Import existing secrets](#import-existing-secrets) · [Commands](#commands)

## Install

mima is in alpha. It targets macOS 12 or later and builds from source with Swift 5.10 or later.

```sh
git clone https://github.com/klobucar/mima.git
cd mima
make install SIGNING_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
mima doctor
```

For Touch ID protection, use an **Apple Development** signing identity and a matching **macOS development provisioning profile** from a paid Apple Developer team. Run `security find-identity -v -p codesigning` to find the identity. In Xcode, building a macOS app with your team selected and automatic signing enabled creates a profile that mima's build can find. You can also pass `PROFILE=/path/to/profile.provisionprofile` to `make install`.

The signed install puts `Mima.app` in `/usr/local/libexec/mima/` and links `/usr/local/bin/mima` to it. Use `PREFIX=` to change the install location. Run `mima doctor` to verify that protected storage works.

**Ad-hoc install.** Plain `make install` stores secrets in the legacy login Keychain. They are encrypted at rest and readable without a prompt by processes running as you while the Keychain is unlocked. If you later switch to a protected build, have the original values on hand. Use `mima doctor` to find unprotected entries, then remove and re-add each one under the signed build.

## Quick start

This example gives the Claude Code CLI one API key. The first command prompts for the value without echoing it.

```sh
mima secret add anthropic-key
mima group link agent-claude ANTHROPIC_API_KEY anthropic-key
mima run --scrub agent-claude -- claude
```

A **secret** is a named Keychain entry. A **group** maps environment variable names, such as `ANTHROPIC_API_KEY`, to those entries. Group mappings live in `~/.mima.yaml` and contain secret names. One secret can belong to multiple groups.

To rotate a key, run `mima secret update anthropic-key`. Existing group mappings continue to use that entry. Use `mima group list` to see the mappings or `mima secret list` to see the stored names.

Use the same pattern for scripts and other tools. For example, `mima run --scrub staging -- ./deploy.sh` loads the `staging` group for the deployment script.

## Use with coding agents

Launch agents with `mima run --scrub` to give them a group and a small set of inherited variables, such as `PATH`, `HOME`, and `TERM`. Pass an extra variable explicitly with `--keep VAR`. The [run reference](#mima-run) lists which variables are carried through.

### Claude Code credential masking

With a Claude Code version that supports sandbox credential settings, use `--claude` to control how sandboxed Bash commands receive group variables.

```sh
mima secret add gh-agent-readonly
mima group link agent-claude GH_TOKEN gh-agent-readonly --host api.github.com
mima run --claude --scrub agent-claude -- claude
```

A variable linked with `--host` appears as a placeholder to sandboxed Bash. Claude Code's proxy substitutes the real value for requests to the listed hosts using its experimental `sandbox.network.tlsTerminate` setting. Group variables without a host are withheld from sandboxed Bash. Repeat `--host` to allow multiple hosts.

mima passes these settings via `claude --settings`. Use `claude` as the executable and put any other Claude settings in user settings. Claude Code itself receives the real values. Hooks and local MCP servers run outside the sandbox and can access the credentials available to them.

### When an agent invokes mima

With a protected build, the unlock prompt names the requested secrets and caller, and flags recognized coding agents. `mima env` and `mima secret get` require a terminal and refuse to print values when they detect an agent, unless invoked with `--force`. The [security model](#security-model) describes the limits of these checks.

## Import existing secrets

### From a dotenv file

```sh
mima import .env --group myapp
```

Each entry becomes a Keychain secret and a mapping in `myapp`. For example, `STRIPE_KEY` becomes `myapp-stripe-key`. Use `--prefix` to choose a different secret name prefix and `--overwrite` to replace existing values. The parser handles `export`, comments, and multiline quoted values. It treats variable references such as `${VAR}` as literal text. The original file stays on disk. Rotate any values from a file that was committed or shared.

### From MCP server configs

```sh
mima mcp import                  # Preview the changes
mima mcp import --apply          # Quit the owning app before applying
mima mcp import --apply --scrub  # Apply with a scrubbed server environment
```

mima scans `~/.claude.json` (including project servers), `./.mcp.json`, Claude Desktop's `claude_desktop_config.json`, and `~/.cursor/mcp.json`. It moves literal credentials from local stdio servers into Keychain groups and rewrites their launch commands to use `mima run`.

Use `--config <path>` to target a specific file or `--all` to import every literal environment value. With `--scrub`, variables still listed in the config are passed through with `--keep`. Before rewriting a file, mima saves a mode-0600 backup containing the original plaintext. After verifying the servers work, remove the backups and rotate any credentials from configs that were committed, shared, or synced.

## Commands

### `mima secret`

```text
mima secret add <name> [--stdin]
mima secret update <name> [--stdin]
mima secret list
mima secret get <name> [--export] [--force]
mima secret rm <name>
```

`add` and `update` prompt without echo. For values of 8 KiB or more or input from another command, pass `--stdin`. It strips one trailing newline. `get --export` prints a shell-quoted export, deriving the variable name from the secret name. For example, `anthropic-key` becomes `ANTHROPIC_KEY`.

### `mima group`

```text
mima group link <group> <ENV_VAR> <secret-name> [--host <hostname>]
mima group unlink <group> <ENV_VAR>
mima group rm <group>
mima group list
```

`unlink` and `rm` remove mappings and leave the Keychain entries available for other groups. Here is what the mapping from the quick start looks like in `~/.mima.yaml`.

```yaml
groups:
  agent-claude:
    ANTHROPIC_API_KEY: anthropic-key
```

### `mima run`

```text
mima run <group> -- <command> [args...]
mima run --scrub --keep <VAR> <group> -- <command> [args...]
mima run --scrub --mask <group> -- <command> [args...]
mima run --scrub --claude <group> -- claude [args...]
```

Put mima flags before the group name and command arguments after `--`. By default, the child inherits your shell environment and group values take precedence.

- **`--scrub`** limits inherited variables to `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TERM`, `TMPDIR`, `LANG`, `TZ`, and `LC_*`. Use repeatable `--keep VAR` with `--scrub` to carry through additional variables, such as `SSH_AUTH_SOCK`.
- **`--mask`** redacts raw and JSON-escaped group secret values of at least four bytes in stdout and stderr, replacing them with `<mima:NAME>`. mima stays running to filter the output, and the command sees pipes for stdout and stderr. This can affect colors and full-screen terminal apps.
- **`--claude`** configures [Claude Code credential masking](#claude-code-credential-masking). Use it without `--mask`.

### `mima env`

```sh
eval "$(mima env <group>)"
```

Replace `<group>` with your group name. `mima env` prints shell-quoted exports. Evaluating them sets the variables in your current shell, where later commands can inherit them. Use `mima run` to scope credentials to a command and its descendants.

### `mima doctor`

```sh
mima doctor
```

Checks signing and Keychain entitlements, tests protected storage by writing and deleting a temporary item, and reports unprotected secrets and group mappings that point to missing secrets. The storage check runs without prompting for Touch ID.

## Security model

A protected install stores secrets in the macOS data protection Keychain with a user-presence requirement. `mima run` uses a single authentication context for the group and passes the values directly in the command's environment. The calling shell receives no new variables.

Commands and their descendants can read the credentials they receive. `--scrub` limits environment inheritance. The process still has access to files, sockets, and other resources available to your account. Caller detection is best effort, and output redaction covers the supported representations of a secret. Review the requested secrets and caller before approving an unlock.

## Roadmap

Per-project config discovery, shell hooks, a trust model for project configs, and a session agent are planned. See [ROADMAP.md](ROADMAP.md) for details.

## Related

[Paprika](https://github.com/klobucar/paprika) is a Secure Enclave SSH agent by the same author.

## License

[MIT](LICENSE)
