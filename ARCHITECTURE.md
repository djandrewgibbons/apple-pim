# Architecture Overview
This document provides a comprehensive understanding of the codebase's architecture, enabling efficient navigation and effective contribution.

## 1. Project Structure

```
apple-pim/
├── lib/                        # Shared JS handler logic used by both mcp-server/ and openclaw/ (symlinked into openclaw/lib)
│   ├── handlers/                 # Per-domain tool handlers translating tool args → Swift CLI invocations
│   ├── cli-runner.js              # Spawns Swift CLI binaries; resolves bin dir; PIMHelper.app routing for TCC
│   ├── schemas.js                 # MCP/OpenClaw tool JSON schemas (single source of truth for both adapters)
│   ├── sanitize.js                # Prompt-injection defense: datamarking/spotlighting untrusted PIM content
│   ├── safe-attachments.js        # Default-deny attachment allow/deny policy (send + save_attachment)
│   ├── safe-shell.js              # Safe child_process spawn wrapper
│   ├── mail-format.js             # Mail body formatting (markdown via turndown, mailparser)
│   ├── mail-quarantine.js         # SQLite-backed gate binding channel drop/observe decisions to the tool layer
│   └── dry-run.js, fields.js, tool-args.js, agent-dx.js   # Agent-DX helpers: dry-run mode, field projection, arg builders
├── mcp-server/                 # MCP stdio adapter (published as apple-pim-mcp)
│   ├── server.js / dist/server.js  # MCP Server entrypoint, wires schemas + handlers, esbuild-bundled
│   ├── build.mjs                   # esbuild bundling script
│   └── test/                       # vitest unit tests
├── openclaw/                   # OpenClaw native plugin (published as apple-pim-cli)
│   ├── src/index.ts                # Plugin entry: registers 5 tools as factories + mail channel + send-approval hook
│   ├── src/mail-channel/           # Inbound Mail.app channel: polling, thread store, quarantine, rate-limit, policy
│   ├── src/mail-auth/              # SPF/DKIM/DMARC-style sender authentication strength scoring
│   ├── lib -> ../lib                # Symlink to shared lib/ (resolved to a real copy at publish time)
│   └── skills/apple-pim/           # Bundled OpenClaw skill docs
├── swift/                      # Swift package: 4 CLIs + shared config library
│   ├── Sources/CalendarCLI/        # EventKit-based calendar CLI
│   ├── Sources/ReminderCLI/        # EventKit + CoreLocation reminders CLI
│   ├── Sources/ContactsCLI/        # Contacts framework CLI
│   ├── Sources/MailCLI/            # AppKit/JXA + raw SQLite/IMAP/SMTP mail CLI (largest, ~7.5K LOC)
│   ├── Sources/PIMConfig/          # Shared library: config/profile loading, allow/blocklist filtering, secrets store
│   └── Tests/*CLITests, PIMConfigTests/  # Swift Testing suites per target
├── helper/                     # PIMHelper.app TCC helper (native "responsible process" for permission prompts)
├── evals/                      # Agent behavior eval suite (scenario-based, vitest + model grading)
├── .github/workflows/          # CI: tests, plugin-inspector, publish (npm/Homebrew/ClawHub), Claude Code bot, site deploy
├── agents/                     # Claude Code subagent definition (pim-assistant.md)
├── skills/                     # Claude Code skill definition + API reference docs (EventKit/Contacts/JXA)
├── commands/                   # Claude Code slash commands (authorize, calendars, mail, etc.)
├── docs/                       # Mail channel scenario docs, multi-agent setup guide
├── scripts/                    # bump-version.sh, check-versions.sh, doctor.sh, build-helper-app.sh
└── site/                       # Astro marketing/docs site deployed to Cloudflare Pages
```

## 2. High-Level System Diagram

```
                     ┌─────────────────────┐         ┌──────────────────────┐
                     │     Claude Code      │         │       OpenClaw        │
                     │  (MCP client, stdio)  │         │ (native tool registry) │
                     └──────────┬───────────┘         └───────────┬───────────┘
                                │ MCP protocol                     │ direct import
                                ▼                                  ▼
                     ┌─────────────────────┐         ┌──────────────────────┐
                     │ mcp-server/server.js │         │  openclaw/src/index.ts │
                     │ (thin adapter)        │         │ (tool factories, mail  │
                     │                        │         │  channel, egress hook) │
                     └──────────┬───────────┘         └───────────┬───────────┘
                                │                                  │
                                └───────────────┬──────────────────┘
                                                 ▼
                                  ┌───────────────────────────┐
                                  │           lib/              │
                                  │  handlers/ · schemas.js      │
                                  │  cli-runner.js · sanitize.js  │
                                  │  safe-attachments.js          │
                                  │  mail-quarantine.js           │
                                  └──────────────┬─────────────┘
                                                 │ spawns (direct or via PIMHelper.app for TCC)
                                                 ▼
              ┌───────────────┬───────────────┬───────────────┬────────────────┐
              │  calendar-cli  │  reminder-cli  │  contacts-cli  │    mail-cli     │
              │  (EventKit)    │ (EventKit+CL)  │  (Contacts)    │ (AppKit/JXA +   │
              │                │                │                │  SQLite+IMAP/  │
              │                │                │                │  SMTP clients)  │
              └───────┬───────┴───────┬───────┴───────┬───────┴────────┬───────┘
                      │               │               │                │
                      ▼               ▼               ▼                ▼
              ┌───────────────────────────────┐               ┌──────────────────────┐
              │     swift/Sources/PIMConfig      │               │  Mail.app / Envelope   │
              │  (allow/blocklist, profiles,     │               │  Index SQLite / IMAP·  │
              │   SecretsStore, config I/O)       │               │  SMTP servers          │
              └───────────────────────────────┘               └──────────────────────┘
                      │
                      ▼
        ~/.config/apple-pim/{config.json, profiles/*.json, secrets.json, mail-attachments.json}
```

## 3. Core Components

### 3.1. `lib/` — Shared handler layer

**Description**: Domain handler modules translate a generic `{action, ...args}` tool call into a Swift CLI invocation. Shared by both the MCP server and the OpenClaw plugin so behavior (validation, filtering, sanitization) never diverges between adapters.

**Technologies**: Node.js ESM.

**Key Files/Directories**:
- `lib/handlers/{calendar,reminder,contact,mail,apple-pim}.js` — one handler per domain
- `lib/cli-runner.js` — process-spawn layer; resolves the Swift binary directory and auto-detects when a call must be routed through `PIMHelper.app` (via `open -W`) for TCC attribution, with per-CLI route caching and stale-helper reaping
- `lib/schemas.js` — single source of truth for tool JSON schemas consumed by both adapters
- `lib/sanitize.js` — prompt-injection defense (datamarking/spotlighting untrusted PIM content, per arXiv:2403.14720)
- `lib/safe-attachments.js` — default-deny attachment policy for mail `send`/`save_attachment`
- `lib/mail-quarantine.js` — SQLite-backed gate binding the mail channel's drop/observe decisions to the tool layer
- `lib/mail-format.js`, `lib/dry-run.js`, `lib/fields.js`, `lib/tool-args.js`, `lib/agent-dx.js` — formatting and agent-DX helpers (dry-run mode, field projection)

### 3.2. `mcp-server/` — MCP adapter

**Description**: Thin MCP stdio server wiring `lib/schemas.js` tools to `lib/handlers/*`, wrapping each call with `withAgentDX` and applying `lib/sanitize.js` datamarking to every result before returning MCP content.

**Technologies**: Node.js, `@modelcontextprotocol/sdk`, esbuild (`build.mjs`) for the bundled `dist/server.js` artifact.

**Key Files/Directories**: `mcp-server/server.js`, `mcp-server/dist/server.js` (generated — rebuild after editing `lib/` or `mcp-server/`), `mcp-server/test/`.

### 3.3. `openclaw/` — OpenClaw native plugin

**Description**: Registers 5 `apple_pim_*` tools as per-workspace factories (not static tools) so each caller can resolve its own `configDir`/`profile` (tool param → workspace convention → plugin config → env var → default), enabling multi-agent workspace isolation. Also owns the inbound Mail.app channel and a `before_tool_call` hook that gates agent-originated sends.

**Technologies**: TypeScript (strict, ES2022, `moduleResolution: bundler`), built with `tsup`, tested with Node's built-in `node --test`.

**Key Files/Directories**:
- `openclaw/src/index.ts` — plugin entry (`definePluginEntry`), tool registration, `resolveSendEgressPolicy`/`evaluateSend` hook
- `openclaw/src/mail-channel/` — polling, thread store, quarantine, rate-limiting, policy for the inbound Mail.app channel
- `openclaw/src/mail-auth/` — SPF/DKIM/DMARC-style sender authentication strength scoring
- `openclaw/lib` — symlink to `../lib`, resolved to a real directory copy by `prepack`/`postpack` at publish time

### 3.4. Swift CLIs (`swift/Sources/*CLI`)

**Description**: Four standalone `ArgumentParser`-based binaries, each reading from a macOS framework (or, for Mail, a mix of native automation and hand-rolled network clients), validating access via `PIMConfig`, and writing JSON to stdout.

**Technologies**: Swift 5.9 tools, `swift-argument-parser`, macOS 13+.

**Key Files/Directories**:
- `CalendarCLI/CalendarCLI.swift` — `import EventKit`; auth-status/list/events/get/search/create/update/delete/batch-create/config
- `ReminderCLI/ReminderCLI.swift` — `import EventKit`, `import CoreLocation` for location-based reminders; adds batch complete/delete and `RepairDates`
- `ContactsCLI/ContactsCLI.swift` — `import Contacts`, `import Security`
- `MailCLI/` (largest module, ~7,500 LOC) — `import AppKit` driving Mail.app via JXA/AppleScript (the authoritative read/write path), plus:
  - `EnvelopeIndex.swift` / `SQLiteEngine.swift` — direct read-only SQLite access to Mail's `~/Library/Mail/V*/MailData/Envelope Index`, a fast read path that works with Mail.app closed (needs Full Disk Access; falls back to JXA on failure). `EngineChoice` (`auto`/`sqlite`/`jxa`) controls the fallback.
  - `EmlxReader.swift` — minimal `.emlx` parser (headers + MIME body) for the SQLite fast path
  - `MessageLocator.swift` — resolves Message-IDs to Envelope Index row IDs to accelerate JXA write-path lookups; every candidate is re-verified by Message-ID on the JXA side, so SQLite never performs the write itself
  - `IMAPClient.swift` — minimal IMAP client (LOGIN/APPEND/LOGOUT) used to append SMTP-sent messages and saved drafts into Sent/Drafts folders
  - `SMTPClient.swift` / `SMTPTransport.swift` / `SMTPSendCommand.swift` — hand-rolled SMTP client and `Network`/`Security`-framework transport (implicit TLS/STARTTLS)
  - `MIMEBuilder.swift` — builds RFC 2822/MIME messages for send/reply
  - `ReplyDraft.swift` — computes reply envelope (from/to/cc) resolution, including Reply-To-over-From spoofing defense, for `reply --draft`

### 3.5. `swift/Sources/PIMConfig` — Shared config library

**Description**: Config/profile loading, allow/blocklist filtering, and secrets access shared by all four CLIs.

**Key Files/Directories**:
- `PIMConfiguration.swift` — Codable config model: per-domain `DomainFilterConfig` (calendars/reminders/contacts: enabled flag, `FilterMode` all/allowlist/blocklist, items), mail's `DomainConfig`, `SMTPDefaults`/`IMAPDefaults` (host/port/username/secretKey — no plaintext passwords)
- `ItemFilter.swift` — allow/blocklist matching (exact name, ID, emoji-stripped fuzzy match)
- `ConfigLoader.swift` / `ConfigWriter.swift` / `ConfigFormatter.swift` — load/write/format config and profile overrides (profile overrides replace whole domain sections, not field-by-field merge)
- `SecretsStore.swift` — see Security Considerations

### 3.6. `helper/` — TCC helper app

**Description**: `PIMHelper.app`, built by `scripts/build-helper-app.sh` into `~/Applications/PIMHelper.app` and lsregistered. macOS TCC attributes Calendar/Reminders/Contacts grants to the "responsible process" (the LaunchServices-launched app), not the CLI binary; wrapping the CLIs in this ad-hoc-signed `.app` and invoking via `open -W` makes the helper its own responsible process, so the permission prompt fires and the grant persists. Not used for Mail (a separate Automation TCC service).

**Key Files/Directories**: `helper/launcher.c`, `helper/Info.plist` (bundle id `com.omarshahine.apple-pim.helper`, `LSUIElement`).

## 4. Data Stores

No independent PIM data store — Calendar/Reminders/Contacts data lives entirely in native EventKit/Contacts stores accessed live via the frameworks. Mail data is read from Apple Mail's own Envelope Index SQLite DB and `.emlx` files on disk, with JXA/AppleScript as the authoritative fallback/write path; the plugin maintains no mail index or cache of its own.

### 4.1. Config store

**Type**: JSON files on disk.

**Purpose**: Base config, per-agent/workspace profile overrides, secrets, attachment policy.

**Key Schemas/Locations**:
- `~/.config/apple-pim/config.json` (base) + `~/.config/apple-pim/profiles/{name}.json` (profile overrides), overridable via `APPLE_PIM_CONFIG_DIR`
- `~/.config/apple-pim/secrets.json` or `~/.openclaw/secrets.json` (shared with the OpenClaw gateway) — see Security
- `~/.config/apple-pim/mail-attachments.json`, overridable via `APPLE_PIM_MAIL_ATTACHMENTS_CONFIG`

### 4.2. Mail channel state

**Type**: SQLite.

**Purpose**: Durable, cross-process store for the inbound mail channel's drop/observe quarantine decisions per message ID, thread permissions, and rate-limit state — moved off in-memory storage after a Greptile review flagged cross-process/eviction bypass risk.

**Key Schemas/Models**: `~/.openclaw/apple-pim/mail-channel.sqlite` (or under `OPENCLAW_STATE_DIR`); accessed via `lib/mail-quarantine.js` and `openclaw/src/mail-channel/{store,thread-store}.ts`.

### 4.3. Mail's native store (read-only)

**Type**: SQLite (Apple Mail's Envelope Index) + `.emlx` files.

**Purpose**: Fast read path for mail listing/search/get, bypassing a Mail.app round-trip.

**Key Schemas/Models**: `~/Library/Mail/V*/MailData/Envelope Index`, read via `EnvelopeIndex.swift`/`SQLiteEngine.swift`/`EnvelopeQueries.swift`; requires Full Disk Access, falls back to JXA when unavailable.

## 5. External Integrations

| Service | Purpose | Integration Method |
|---------|---------|-------------------|
| EventKit | Calendar and Reminders CRUD, permissions | Native framework (CalendarCLI, ReminderCLI) |
| Contacts framework | Contact CRUD/search | Native framework (ContactsCLI) |
| Mail.app | Authoritative mail read/write, automation permission required | JXA/AppleScript via `AppKit`/`NSAppleScript` (MailCLI) |
| IMAP/SMTP servers | Direct send, Sent/Drafts folder APPEND | Hand-rolled Swift clients (`IMAPClient.swift`, `SMTPClient.swift`, `SMTPTransport.swift`) over `Network`/`Security` frameworks |
| MCP protocol | Exposes tools to Claude Code | `@modelcontextprotocol/sdk` stdio server (`mcp-server/server.js`) |
| OpenClaw plugin system | Native tool registration for OpenClaw agents | `definePluginEntry`/`registerTool`, `before_tool_call` hook (`openclaw/src/index.ts`) |
| GitHub Actions | CI, publishing | `.github/workflows/*.yml` |
| Dependabot | Dependency updates | `.github/dependabot.yml` (monthly, grouped) |
| Greptile | Automated PR code review | `@greptile review` PR comment trigger |
| Clawpatch | Local automated code review | `.clawpatch/` gitignored generated state |

## 6. Deployment & Infrastructure

**Platform**: npm registry, ClawHub, and a Homebrew tap (`omarshahine/homebrew-tap`) for the OpenClaw plugin (`apple-pim-cli`); Cloudflare Pages for the marketing/docs site.

**CI/CD**: GitHub Actions. Three independent publish workflows trigger on `push: tags: ["v*"]`, each gated by a shared `preflight` job (`.github/actions/openclaw-sdk-contract`) that refuses to publish unless the OpenClaw SDK ships the channel-ingress contract the code depends on:
- `publish-npm.yml` — OIDC Trusted Publisher npm publish with provenance, tag/version assertion, and post-publish registry polling
- `publish-clawhub.yml` — `npm run prepack` (resolves `lib/` symlink) → `clawhub package publish` → `clawhub package inspect --version` verification
- `publish-homebrew.yml` — bumps the `apple-pim-cli` formula in the tap repo from a GitHub source tarball
- `deploy-site.yml` — deploys `site/` (Astro) to Cloudflare Pages on push to `main`
- `plugin-inspector.yml` — `@openclaw/plugin-inspector` checks on every PR/push to main
- `tests.yml` — required checks: `mcp-server-tests`, `agent-evals`, `swift-cli-tests`, `version-check`; `openclaw-plugin-tests` is intentionally not required (currently skips pending an OpenClaw SDK release)

**Key Config Files**: `scripts/bump-version.sh` (rewrites all 5 version sources + rebuilds `mcp-server/dist/server.js`), `scripts/check-versions.sh` (CI: `omarshahine/version-consistency-action@v1`), `publish-clawhub.sh` (manual fallback), `setup.sh` (build + install), `scripts/build-helper-app.sh`, `scripts/doctor.sh`.

## 7. Security Considerations

**Authentication**: No user-facing auth — access is macOS TCC permission-gated (Calendar/Reminders/Contacts full access, Mail Automation, Full Disk Access for the SQLite read path). `apple-pim.js`'s `status`/`authorize` actions call each CLI's `auth-status`.

**Authorization / data-scoping**: `PIMConfig`'s `ItemFilter` enforces per-domain allowlist/blocklist filtering (calendars, reminder lists, contact groups) with exact-name, ID, and emoji-stripped fuzzy matching; profiles allow per-workspace/per-agent scoping (`APPLE_PIM_PROFILE`, `APPLE_PIM_CONFIG_DIR`, or per-call `configDir`/`profile` in OpenClaw). Config filtering happens entirely in the Swift CLIs — the MCP server does no filtering itself, only passes `--profile` through.

**Key Security Files**:
- `lib/safe-attachments.js` — default-deny outbound attachment policy (disabled unless `~/.config/apple-pim/mail-attachments.json` opts in with `allowedRoots`); a hard denylist (`.ssh`, `.aws`, `.netrc`, `id_rsa`, `*.pem`, `*secret*`, `*password*`, `*credential*`, `*token*`, etc.) always wins, with symlink canonicalization (`realpathSync`) to prevent root-escape. `validateDestDir` applies the same denylist to `save_attachment` output paths; a mirrored authoritative check exists Swift-side in `MailCLI.swift`.
- `lib/sanitize.js` — datamarking/spotlighting (per arXiv:2403.14720) wraps untrusted PIM content in randomized per-session delimiter tokens and flags suspicious instruction-like/exfiltration-like patterns before returning content to the calling agent.
- `lib/mail-quarantine.js` — SQLite-backed binding of the mail channel's drop/observe decisions to the tool layer: `assertMailReadable` blocks reading a refused message, `assertMailRepliable` separately blocks replying to an observe-only message, `filterQuarantinedResults` strips withheld rows from listings/searches (withheld-count is deliberately not reported, to avoid a content oracle).
- `openclaw/src/index.ts`'s `before_tool_call` hook (`resolveSendEgressPolicy`/`evaluateSend`) — gates agent-originated `mail send` calls against the channel's allowlist/loop-guard, requiring human approval for unlisted recipients and unconditionally refusing sends that loop back to the agent's own address.
- `swift/Sources/PIMConfig/SecretsStore.swift` — dot-key JSON-pointer secrets store, strict key validation, read precedence: env var (e.g. `smtp.icloud.password` → `SMTP_ICLOUD_PASSWORD`) → `~/.openclaw/secrets.json` → `~/.config/apple-pim/secrets.json`. Files written atomically at mode `0600`, permission-checked on every read (warns if wider), with a `.metadata_never_index` Spotlight-exclusion marker. `list()` never returns values, only key names. Config files (`SMTPDefaults`/`IMAPDefaults`) hold no plaintext credentials, only `secretKey` references.
- `ReplyDraft.swift`'s `resolveIMAPDraftAccount` — Reply-To-over-From spoofing defense and account-boundary check for `reply --draft`, fails closed when the account alias list can't be determined.

## 8. Development Environment

**Prerequisites**: Node.js ≥22.13 (openclaw `engines`; CI runs Node 20 and 24), Swift 5.9 tools / macOS 13+ target, Xcode (latest, for `swift test` on CI's macOS runner).

**Setup**: `./setup.sh` builds the Swift CLIs (`swift build -c release`), installs root/mcp-server npm deps, and optionally installs binaries to `~/.local/bin` (copy by default, `--link` for symlink dev mode). `scripts/doctor.sh` runs full-environment diagnosis.

**Testing**:
- Swift: Swift Testing (`import Testing`) under `swift/Tests/{CalendarCLITests, ReminderCLITests, ContactsCLITests, MailCLITests, PIMConfigTests}`; run via `cd swift && swift test`
- JS: `vitest` under `mcp-server/test/*.test.js` and `evals/tests/*.test.js`; `node --test` for `openclaw/src/**/*.test.ts` (CI-skipped pending an OpenClaw SDK release)
- Agent evals: YAML-defined scenarios (`evals/scenarios/*.yaml`) run through `evals/helpers/{scenario-runner,grader,model-grader,mock-cli}.js` against canned fixtures (`evals/fixtures/`); `npm run eval` from repo root. Calendar-reasoning evals additionally call `claude -p` with an LLM judge and require `ANTHROPIC_API_KEY` (non-deterministic, ~$2.31/~8min for a full run) — CI runs with `SKIP_MODEL_EVALS=1`.

**Code Quality**: No dedicated JS/TS linter or formatter config found (no `.eslintrc`, `.prettierrc`) in the repo root, `mcp-server/`, or `openclaw/`. `pr-review-toolkit` enforces TODO/FIXME-as-issue, no emoji in commits, verb-first commit messages on every PR. Greptile handles automated PR code review (`@greptile review`); Clawpatch provides local automated review (`clawpatch review`).

## 9. Project Identification

**Project Name**: apple-pim

**Repository**: https://github.com/djandrewgibbons/apple-pim.git

**Last Updated**: 2026-08-31
