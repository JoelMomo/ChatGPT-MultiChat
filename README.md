# ChatGPT MultiChat

A portable Windows coordination layer for running **multiple ChatGPT chats through Desktop Commander on the same PC at the same time**.

ChatGPT MultiChat reduces collisions between parallel chats by giving each managed chat its own session, slot, color, optional isolated Git worktree, development port, and shared-resource locks.

> Current version: **v2.2.0**

## Why it exists

When several chats execute local commands independently, they can easily:

- edit the same repository at the same time;
- start development servers on the same port;
- compete for ADB, fastboot, scrcpy, an Android emulator, or another exclusive resource;
- leave behind terminal sessions that are hard to identify;
- overwrite or interfere with another chat's work.

MultiChat turns those independent shells into coordinated sessions.

## How it works

```text
ChatGPT A ─┐
ChatGPT B ─┼─> Start-McpChatSession.ps1
ChatGPT C ─┘          │
                      ├─ assigns CHAT-1 ... CHAT-8
                      ├─ tracks status and activity
                      ├─ creates an isolated Git worktree/branch when appropriate
                      ├─ reserves a development port
                      ├─ applies shared-resource locks
                      └─ appears in the MultiChat dashboard
```

Each chat should open **one persistent managed session** and reuse that same process/PID for the entire task. All later commands for that chat should be sent to the same session.

## Main features

- Up to **8 simultaneous managed chats**, each with a fixed slot color.
- Isolated Git worktrees and branches for repository work.
- Exact-base worktree creation with optional `BaseRef` + full `BaseSha` validation.
- Optional declared `CanonicalRef` for fail-closed integration/cleanup checks.
- Automatic development-port reservation.
- Dynamic resource identities, including Android serials and AVD names.
- Explicit resource wrappers that hold a lock for an entire operation.
- Persistent external-executor leases with heartbeat/TTL and conservative stale handling.
- Activity classification such as `READY`, `BUILD`, `TEST`, `GIT`, `ADB`, `SERVER`, and `WAIT`.
- Redesigned WinForms tray dashboard with a cleaner dark UI, metric cards, and improved table readability.
- Short history of completed sessions.
- Automatic background cleanup of finished worktrees that are verified `SAFE`, with manual cleanup retained as a fallback.
- Recovery of abandoned sessions and dead owner processes.
- Desktop Commander connection status with green/yellow/red LED, plus an On/Off connection switch.
- Automatic hidden restart of Desktop Commander while the connection switch is On.
- No automatic Windows startup.
- Portable package with no machine-specific paths or runtime state.

## What's new in v2.2.0

- Added exact Git base contracts: `-BaseRef` and full 40-character `-BaseSha` must resolve to the same commit or session creation fails closed.
- Worktrees are created from the validated SHA instead of implicit local `HEAD`.
- Added optional `-CanonicalRef` and cleanup rules that prove either zero own commits relative to `baseSha` or integration into the declared canonical ref.
- Added persistent leases for external executors. `ACTIVE`, `STALE`, `MISMATCH`, and `UNKNOWN` leases protect sessions from expiry, reservation release, and cleanup.
- Added `Invoke-ManagedExternal.ps1` with automatic lease heartbeat and resource retention for long-running external processes.
- Added dynamic Android resource identities such as `android:serial:<serial>` and `android:avd:<name>`; different devices can run concurrently while the same identity collides.
- Added explicit `Invoke-WithChatResource(s)` wrappers for operations that must hold a resource independently of command-regex detection.
- Added `Validate-ManagedSession.ps1` for fail-closed post-execution validation of workspace, base, worktree identity, and lease state.
- Cleanup now verifies exact worktree identity and refuses legacy/ambiguous states such as `BASE_UNKNOWN`, `FOREIGN_WORKTREE_STATE`, or protective leases.
- Replaced the Desktop Commander switch's native CheckBox rendering with a fully custom-drawn panel so hover no longer paints a gray Windows background.
- Added `HardeningTest.ps1` covering resource concurrency, exact-base mismatch, lease expiry/cleanup veto, stale/unknown lease behavior, canonical integration, and SAFE cleanup.

## What's new in v2.1.2

- Fixed the minimize-button container so its hover square is always fully visible.
- Replaced the header's flow layout with fixed-position window controls.
- Added a status LED for Desktop Commander: green `ONLINE`, yellow `CONNECTING`, red `OFFLINE`.
- Added a connection switch in the header. It defaults to On at every app launch.
- Switching Off stops Desktop Commander and disables automatic reconnect attempts until the switch is turned On again.
- Switching On starts Desktop Commander when needed and transitions through `CONNECTING` to `ONLINE`.

## What's new in v2.1.1

- Fixed the minimize button hover state and centered its glyph.
- Replaced unreliable form-level resizing with eight dedicated resize grips for edges and corners.
- Clarified Git tooltips: for example, `23 new` now explains that those files are not tracked by Git.
- Finished `SAFE` worktrees are cleaned automatically in the background instead of continuously accumulating.
- Auto-clean skips worktrees whose owner process is still alive and keeps manual cleanup as a fallback.
- Stale folders that no longer resolve to their own Git worktree are classified as `NOT_A_WORKTREE` and retained instead of being deleted without verifiable Git state.

## What's new in v2.1.0

- Refreshed dashboard using Segoe UI, flatter controls, status cards, and clearer visual hierarchy.
- Borderless dark window chrome replaces the native white Windows title bar; the custom header remains draggable.
- Git state is now shown with readable labels such as `Clean`, `28 new`, `4 changed`, `ahead 2`, and `behind 1`.
- Worktree scanning and cleanup run in hidden worker processes instead of blocking the UI thread.
- Cleanup uses cached candidates, clears stale counts immediately, revalidates candidates before deletion, and reports failed removals.
- Git summaries, session expiry, liveness validation, and Desktop Commander health checks run in a hidden maintenance worker instead of the UI thread.
- Grid cells are updated only when their displayed value changes.
- Expensive Git checks are avoided during ordinary one-second status refreshes.
- The dashboard reads active sessions through the eight slot files instead of scanning the full session history on every refresh.
- Session/project registry handling is more defensive against malformed stale entries.
- UI helpers are isolated in `MultiChat.UI.ps1`, while performance-sensitive runtime logic is consolidated in `ChatMulti.Advanced.ps1`.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or later.
- Git.
- Node.js with `npx`.
- Desktop Commander available through `npx`.

## Quick install

1. Download the portable ZIP from the latest GitHub release.
2. Extract it to a permanent folder.
3. Run `Setup.cmd`.
4. A **ChatGPT MultiChat Agent** shortcut is created on the desktop.
5. Open the agent before starting parallel Desktop Commander work.

`Setup.cmd` does **not** configure automatic startup.

## Using it with ChatGPT

The easiest approach is to give ChatGPT the contents of `PROMPT-FOR-CHATGPT.txt`.

The essential instruction is:

```text
Use the ChatGPT MultiChat system installed on this PC for any Desktop Commander work.
Start one persistent session with Start-McpChatSession.ps1, reuse its PID for the entire task,
and do not modify the project through loose MCP shells. If you work in a Git repository,
use the isolated worktree assigned by MultiChat. Respect resource locks and the assigned port.
```

A chat should start a session similar to:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File "C:\path\to\ChatGPT-MultiChat\Start-McpChatSession.ps1" `
  -ProjectPath "C:\path\to\project" `
  -Task "short-task-description"
```

From that point onward, all commands for that task should be sent to the **same PID**.

### Exact-base sessions

When an orchestrator already knows the exact base it expects, pass both the ref and the full SHA:

```powershell
Start-McpChatSession.ps1 `
  -ProjectPath "C:\path\to\project" `
  -Task "validated-task" `
  -BaseRef "origin/main" `
  -BaseSha "0123456789abcdef0123456789abcdef01234567" `
  -CanonicalRef "origin/main"
```

MultiChat does not silently move the requested base. `BaseRef` and `BaseSha` must resolve to the same commit or session creation fails. The caller is responsible for fetching/revalidating the desired ref before starting the session when freshness matters.

`CanonicalRef` is optional. When supplied, it is used later to prove whether commits created in the managed worktree have been integrated. MultiChat never auto-merges them.

For work that should not create a Git worktree:

```powershell
Start-McpChatSession.ps1 `
  -ProjectPath "C:\path\to\project" `
  -Task "test" `
  -NoWorktree
```

Type `exit` or `quit` inside the managed session to release it cleanly.

## Dashboard

The dashboard shows one row per active managed chat:

| Field | Meaning |
|---|---|
| Chat | Assigned slot (`CHAT-1` ... `CHAT-8`) |
| Project | Associated project |
| Activity | `FREE`, `WORKING`, or `ABANDONED` |
| Detail | Detected command/activity type |
| Time | Time since the last state update |
| Git | Compact Git summary |
| Port | Development port reserved for the session |
| Task | Task description supplied when the session started |
| Warning | Conflicts or conditions that need attention |

Closing the dashboard window does **not** stop the agent. It remains in the Windows system tray. Use **Exit** from the tray menu to stop it completely.

### Dashboard performance

The visible chat state still refreshes quickly, but expensive work is decoupled from that timer:

- the one-second UI refresh reads only the active slot index and cached values;
- Git summaries, session expiry, PID validation, and Desktop Commander process detection run in a hidden maintenance worker;
- recent history is refreshed separately;
- worktree scanning runs in its own hidden worker;
- worktree cleanup also runs in a hidden worker;
- refresh pauses while the window is moved or resized.

This keeps the WinForms UI responsive even when Git operations take around a second on a larger set of worktrees.

## Session states and expiry

When a managed session is in `READY`, the dashboard displays it as `FREE`. If it remains idle for the configured amount of time, it becomes `ABANDONED`.

Default behavior:

- `ABANDONED`: after 3 minutes in `READY`.
- Clean idle session: may be released after 10 minutes.
- Idle session with local changes: waits 20 minutes.
- Active work such as `BUILD`, `TEST`, `ADB`, or `SERVER`: does not expire while that activity is active.

If the process that owns a session disappears, MultiChat can release its slot, port, and resource locks **only when no protective external lease exists**. An `ACTIVE`, `STALE`, `MISMATCH`, or `UNKNOWN` lease keeps the session fail-closed.

## Git worktrees

Cleanup is deliberately fail-closed.

A finished managed worktree is `SAFE` only when MultiChat can prove all of the following:

- there is no protective lease;
- the workspace is still the exact worktree registered by the originating repository;
- the expected managed branch still matches that worktree;
- the tree has no tracked modifications or untracked files;
- a valid persisted `baseSha` exists and is an ancestor of the worktree HEAD;
- either the worktree has **zero own commits** relative to `baseSha`, or its HEAD is demonstrably integrated into the declared `canonicalRef`.

If any proof is missing, the result is `KEEP`, not deletion. Examples include `BASE_UNKNOWN`, `BASE_INCORRECT`, `CANONICAL_REF_MISSING`, `UNMERGED_COMMITS`, `WORKSPACE_MISMATCH`, `FOREIGN_WORKTREE_STATE`, and protective lease states.

Legacy session records that predate persisted `baseSha` are therefore not auto-cleaned merely because they look clean.

You can still use:

- **Clean safe worktrees** in the dashboard as a manual fallback;
- `Cleanup-Worktrees.ps1` to inspect candidates and reasons;
- `Cleanup-Worktrees.ps1 -Apply` to apply only candidates that remain `SAFE` after immediate revalidation.

The dashboard rescans periodically in the background and reports only the candidates that remain after automatic cleanup.

## Shared-resource locks

Resources are identified by **real identity** whenever possible instead of one global Android lock.

Examples:

- `android:serial:THOR_SERIAL`
- `android:serial:emulator-5554`
- `android:avd:pixel_test`
- `android-sdk`

ADB/fastboot/scrcpy commands with an explicit `-s <serial>` are locked by serial. Emulator launches with `-avd <name>` are locked by AVD name. Two different serials or AVDs can therefore run concurrently, while two operations targeting the same identity collide.

When an ADB-style command omits the serial, MultiChat uses `ANDROID_SERIAL` when present, otherwise it resolves a single connected ADB device when that is unambiguous. If it cannot prove one device identity, it falls back to the conservative `android:adb-default` resource. Ambiguous ADB/fastboot resources conflict with every `android:serial:*` lock, so uncertainty reduces concurrency rather than risking two operations on the same device.

Regex rules in `config.json` remain available for additional static shared resources, but Android serial/AVD isolation is resolved dynamically.

For operations where the lock must remain held for the **entire wrapper operation**, use:

```powershell
Invoke-WithChatResource -Resource "android:serial:emulator-5554" -ScriptBlock {
    # complete operation here
}
```

or `Invoke-WithChatResources` for multiple identities. These wrappers are independent of command-line regex detection.

## External executor leases

Long-running external executors can outlive the interactive shell that launched them. A lease keeps the managed session, worktree, slot, development port, and lease-owned resource locks protected while that executor is active.

Core commands:

- `New-ChatLease`
- `Update-ChatLease` for heartbeat/renewal
- `Close-ChatLease`
- `Invoke-WithChatLease`

For a complete external process wrapper with automatic heartbeat:

```powershell
.\Invoke-ManagedExternal.ps1 `
  -SessionId $env:CHATGPT_SESSION_ID `
  -Owner "external-validator" `
  -Resource "android:serial:emulator-5554" `
  -FilePath "powershell.exe" `
  -ArgumentList @("-NoProfile","-File","run-validation.ps1")
```

Lease states are conservative:

- `ACTIVE`: execution is protected;
- `STALE`: heartbeat expired, but MultiChat still protects the session;
- `MISMATCH`: lease snapshot does not match session/workspace/base;
- `UNKNOWN`: lease evidence exists but cannot be safely interpreted;
- `NONE`: no protective lease is present.

Only `NONE` permits ordinary expiry/release/cleanup. Stale, mismatched, or unreadable lease evidence is never treated as permission to delete work.

`Validate-ManagedSession.ps1` can be used after an external execution to fail closed on workspace/base/lease mismatches:

```powershell
.\Validate-ManagedSession.ps1 `
  -SessionId $env:CHATGPT_SESSION_ID `
  -ExpectedWorkspace $env:CHATGPT_WORKSPACE `
  -ExpectedBaseSha $env:CHATGPT_BASE_SHA `
  -RequireLease
```

## Development ports

Each managed session can reserve a different development port.

The default range starts at port `3000` and contains 100 configurable positions. This prevents two managed chats from accidentally starting development servers on the same port.

## Configuration

The main settings live in `config.json`:

| Setting | Default | Purpose |
|---|---:|---|
| `maxSlots` | 8 | Maximum simultaneous managed chats |
| `refreshSeconds` | 1 | Lightweight chat-status/UI refresh interval |
| `maintenanceRefreshSeconds` | 15 | Background Git, expiry, liveness, and Desktop Commander maintenance interval |
| `historyRefreshSeconds` | 5 | Recent-history refresh interval |
| `cleanupScanSeconds` | 30 | Background worktree-scan interval |
| `autoCleanSafeWorktrees` | true | Automatically remove finished worktrees that pass all SAFE checks |
| `defaultLeaseTtlMinutes` | 60 | Default external-executor lease TTL when a caller does not supply one |
| `abandonedAfterMinutes` | 3 | Time before a READY session is marked abandoned |
| `cleanExpireMinutes` | 10 | Expiry for clean idle sessions |
| `dirtyExpireMinutes` | 20 | Expiry for idle sessions with local changes |
| `portRangeStart` | 3000 | First reservable development port |
| `portRangeCount` | 100 | Number of ports in the reservation pool |
| `historyLimit` | 50 | Maximum stored history entries |

Additional static resource-lock rules are defined in `config.json`. Android serial and AVD identities are resolved dynamically by MultiChat.

## Main files

| File | Purpose |
|---|---|
| `ChatMulti.psm1` | Session-management core and module loader |
| `ChatMulti.Advanced.ps1` | Configuration cache, ports, history, project resolution, Git/status, cleanup, idle-state, conflicts, and reservations |
| `ChatMulti.Hardening.ps1` | Exact-base validation, dynamic resource identities, leases, worktree identity, canonical integration checks, and fail-closed validation |
| `MultiChat-Tray.ps1` | Lightweight dashboard orchestration and system-tray agent |
| `MultiChat.UI.ps1` | Reusable WinForms styling and UI helpers |
| `MultiChat-Maintenance.ps1` | Background Git, expiry, liveness, and Desktop Commander maintenance worker |
| `Start-McpChatSession.ps1` | Starts and owns one persistent managed chat session |
| `Setup.cmd` / `Setup.ps1` | Local setup and desktop shortcut |
| `config.json` | Portable configuration |
| `PROMPT-FOR-CHATGPT.txt` | Ready-to-paste ChatGPT instruction |
| `SelfTest.cmd` / `SelfTest.ps1` | System validation |
| `Cleanup-Worktrees.ps1` | Fail-closed worktree cleanup and diagnostic result output |
| `Validate-ManagedSession.ps1` | Post-execution workspace/base/lease validator |
| `Invoke-ManagedExternal.ps1` | Long-running external-process wrapper with lease heartbeat and resource retention |
| `HardeningTest.ps1` | Concurrency, exact-base, lease, and cleanup safety test suite |
| `Show-History.ps1` | Session-history viewer |
| `Make-Portable-Package.ps1` | Builds the portable release ZIP |

## Self-test

Run:

```cmd
SelfTest.cmd
```

Expected result:

```text
SELF-TEST: OK
Dependencies, scripts, configuration, registry robustness, slots, colors and ports: OK.
```

The self-test checks dependencies, PowerShell syntax, configuration, slot behavior, UI controls, port reservation, and then runs `HardeningTest.ps1`. The hardening suite verifies dynamic-resource concurrency, exact-base creation and mismatch rejection, lease protection, stale/unknown fail-closed behavior, canonical integration, and SAFE cleanup.

## Portability

The project uses paths relative to its own folder.

`Make-Portable-Package.ps1` creates a ZIP without copying machine-local runtime state, logs, sessions, leases, or worktrees. The package recreates empty runtime directories, including `state\leases`, on the target machine.

To build a package:

```powershell
.\Make-Portable-Package.ps1 -Version "2.2.0"
```

## Limitations

MultiChat coordinates processes that **use the MultiChat session system**. It cannot prevent an unrelated terminal, another application, or a chat that ignores the manager from directly editing the same repository or using the same external resource.

The key rule is therefore:

**one chat → one persistent managed session → one reused PID for the entire task.**

## Uninstall

1. Exit the agent from the system-tray icon.
2. Delete the desktop shortcut.
3. Delete the ChatGPT MultiChat folder.

No Windows service or automatic-start entry is installed.
