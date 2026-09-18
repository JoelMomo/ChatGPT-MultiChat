# ChatGPT MultiChat

A portable Windows coordination layer for running **multiple ChatGPT chats through Desktop Commander on the same PC at the same time**.

ChatGPT MultiChat reduces collisions between parallel chats by giving each managed chat its own session, slot, color, optional isolated Git worktree, development port, and shared-resource locks.

> Current version: **v2.1.0**

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
- Automatic development-port reservation.
- Configurable locks for shared resources.
- Activity classification such as `READY`, `BUILD`, `TEST`, `GIT`, `ADB`, `SERVER`, and `WAIT`.
- Redesigned WinForms tray dashboard with a cleaner dark UI, metric cards, and improved table readability.
- Short history of completed sessions.
- Background safe-cleanup detection for finished worktrees.
- Recovery of abandoned sessions and dead owner processes.
- Automatic hidden restart of Desktop Commander when it is no longer available.
- No automatic Windows startup.
- Portable package with no machine-specific paths or runtime state.

## What's new in v2.1.0

- Refreshed dashboard using Segoe UI, flatter controls, status cards, and clearer visual hierarchy.
- Worktree scanning and cleanup run in hidden worker processes instead of blocking the UI thread.
- Cleanup uses cached candidates and revalidates only worktrees that are about to be removed.
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

If the process that owns a session disappears, MultiChat can release its slot, port, and resource locks.

## Git worktrees

MultiChat does **not** delete a worktree just because its chat ends.

A finished worktree is considered safe to remove only when it has no uncommitted local changes and no commits that still need to be integrated.

You can use:

- **Clean safe worktrees** in the dashboard. The button returns immediately while cleanup runs in the background;
- `Cleanup-Worktrees.ps1` to inspect candidates;
- `Cleanup-Worktrees.ps1 -Apply` to apply safe cleanup.

The dashboard scans for cleanup candidates periodically in the background. When cleanup is requested, the cached safe candidates are passed to the worker and revalidated immediately before deletion.

## Shared-resource locks

`config.json` contains regular-expression rules that identify commands requiring exclusive access.

The included configuration protects, among other things:

- ADB;
- fastboot;
- scrcpy;
- connected Gradle/APK installation operations;
- Android emulator and SDK-management tools.

If another managed chat already owns the relevant lock, the new operation is blocked instead of being executed concurrently.

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
| `abandonedAfterMinutes` | 3 | Time before a READY session is marked abandoned |
| `cleanExpireMinutes` | 10 | Expiry for clean idle sessions |
| `dirtyExpireMinutes` | 20 | Expiry for idle sessions with local changes |
| `portRangeStart` | 3000 | First reservable development port |
| `portRangeCount` | 100 | Number of ports in the reservation pool |
| `historyLimit` | 50 | Maximum stored history entries |

Resource-lock rules are also defined in `config.json`.

## Main files

| File | Purpose |
|---|---|
| `ChatMulti.psm1` | Session-management core and module loader |
| `ChatMulti.Advanced.ps1` | Configuration cache, ports, history, project resolution, Git/status, cleanup, idle-state, conflicts, and reservations |
| `MultiChat-Tray.ps1` | Lightweight dashboard orchestration and system-tray agent |
| `MultiChat.UI.ps1` | Reusable WinForms styling and UI helpers |
| `MultiChat-Maintenance.ps1` | Background Git, expiry, liveness, and Desktop Commander maintenance worker |
| `Start-McpChatSession.ps1` | Starts and owns one persistent managed chat session |
| `Setup.cmd` / `Setup.ps1` | Local setup and desktop shortcut |
| `config.json` | Portable configuration |
| `PROMPT-FOR-CHATGPT.txt` | Ready-to-paste ChatGPT instruction |
| `SelfTest.cmd` / `SelfTest.ps1` | System validation |
| `Cleanup-Worktrees.ps1` | Safe worktree cleanup |
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

The test checks dependencies, PowerShell syntax, configuration, slot behavior, fixed colors, and port reservation.

## Portability

The project uses paths relative to its own folder.

`Make-Portable-Package.ps1` creates a ZIP without copying machine-local runtime state, logs, sessions, or worktrees.

To build a package:

```powershell
.\Make-Portable-Package.ps1 -Version "2.1.0"
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
