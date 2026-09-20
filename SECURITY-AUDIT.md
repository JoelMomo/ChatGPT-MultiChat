# Security audit

Audit date: 2026-09-19
Scope: ChatGPT MultiChat + Remote Desktop Commander on Windows.

## Threat model

The primary security objective is to prevent a remote human attacker, a compromised AI account, or a maliciously instructed AI from turning MultiChat into an unauthenticated or silently elevated path into the Windows host.

The audit assumes that content read from repositories, issues, logs, web pages, and files can be hostile. MultiChat session rules are not treated as a security boundary by themselves.

## Verified properties

- MultiChat does not expose an inbound Remote Desktop Commander listener. The remote agent uses authenticated outbound HTTPS connections.
- Windows Firewall is enabled and inbound traffic is blocked by default on the active public network profile.
- Windows Defender real-time protection, behavior monitoring, network inspection, and tamper protection were enabled during the audit.
- Remote Desktop Commander runs with a medium-integrity user token. UAC remains the boundary for administrator-level actions.
- Direct writes to Program Files and HKLM Run were denied from the remote execution context.
- The persisted Remote Desktop Commander authorization and local Desktop Commander configuration are ACL-restricted to the current user, SYSTEM, and Administrators.
- The former Remote Desktop Commander device created before reauthorization was removed server-side.

## Adversarial capability probes

Harmless canary probes confirmed that an authorized Remote Desktop Commander session currently has the normal powers of the signed-in Windows user:

| Probe | Result |
|---|---|
| Write to Startup folder | Allowed |
| Write HKCU Run persistence value | Allowed |
| Create limited scheduled task | Denied |
| Write Program Files | Denied |
| Write HKLM Run | Denied |
| Decrypt a synthetic CurrentUser DPAPI secret | Allowed |
| Direct Desktop Commander file-tool access outside allowed project roots | Denied |
| Shell access to the same out-of-scope user files | Allowed |
| Remote mutation of Desktop Commander configuration (`set_config_value`) | Allowed |

All persistence canaries were removed immediately after the test.

The DPAPI result is important: a fully malicious but correctly authorized remote agent is not contained from secrets and files available to the signed-in user. UAC protects administrator-only locations, but it does not isolate one process running as the same user from that user's data.

The audit also verified, without extracting secret values, that browser login/cookie databases and credential-manager-backed application authentication are reachable to the signed-in user. GitHub CLI is authenticated through the Windows keyring. File-tool folder scoping blocks direct `read_file`-style access outside approved roots, but terminal/process tools run as the same Windows user and can bypass that scope. Remote `set_config_value` can also alter Desktop Commander's own guardrail configuration, so those settings are not a containment boundary.

## Hardening implemented

- Desktop Commander is pinned to the reviewed package version instead of using `@latest`.
- Remote Desktop Commander starts **Off** on every MultiChat launch and must be enabled locally; an Off switch state also terminates any leftover remote process.
- MultiChat no longer persists Desktop Commander stdout/stderr containing tool arguments and results.
- Local Desktop Commander telemetry is disabled.
- Remote authorization and Desktop Commander local state are protected by restrictive ACLs.
- Desktop Commander file tools are automatically scoped to registered project roots plus the conventional `source\repos` development root. Direct file-tool access outside that scope is rejected.
- Dashboard ONLINE state requires a persisted authorization record plus an established Remote Desktop Commander HTTPS connection.
- An emergency disconnect stops Remote Desktop Commander, revokes the current server-side device row and authentication session when possible, removes local authorization, and records only non-secret result metadata.
- Remote access disconnects when Windows is locked by default.
- Remote access disconnects after 30 minutes with no managed chats by default.
- Sensitive Desktop Commander local tool history is purged when remote access is stopped by default.
- Exiting MultiChat stops Remote Desktop Commander rather than leaving the remote agent behind.
- `SecurityTest.ps1` validates the security-critical configuration and local ACL state.
- The managed-chat prompt explicitly treats repository files, web content, issues, logs, terminal output, and downloaded artifacts as untrusted data and forbids external content from authorizing security-sensitive actions.
- Optional **Restricted Remote** containment runs Remote Desktop Commander under a dedicated local standard Windows identity with a separate DPAPI/profile boundary, read-only access to approved canonical Git metadata, isolated shared-clone workspaces, a kill-on-close job object, a clean child environment, and explicit review-branch import instead of direct canonical-repository writes.
- Restricted Remote installation is path/SID driven rather than machine-name/user-profile hard-coded, and `PortabilityTest.ps1` rejects tracked executable scripts containing machine-specific user-profile paths or the current computer name.
- Portable release construction copies Git-tracked application files only, preventing unrelated local helper scripts, patches, credentials, or other untracked checkout files from leaking into a release ZIP.

The three exposure controls above can be overridden by adding these optional settings to `config.json`:

```json
{
  "remoteDisconnectOnLock": true,
  "remoteIdleDisconnectMinutes": 30,
  "remotePurgeHistoryOnDisconnect": true
}
```

The values shown are the secure defaults used when the properties are absent.

## Residual risk

In normal mode, Remote Desktop Commander still runs as the interactive Windows user. Therefore a correctly authorized but hostile AI can potentially read, alter, delete, or exfiltrate data that the user account can access and can use user-level persistence mechanisms. Browser credential stores, CurrentUser DPAPI material, Windows Credential Manager entries, and application keyrings are part of this same-user risk surface.

Command blocklists, path allowlists, MultiChat leases, and worktree rules are useful guardrails but are not a containment boundary against a deliberately hostile process running as the same Windows identity. In particular, `allowedDirectories` protects Desktop Commander's direct filesystem tools, but terminal commands still execute with the Windows user's permissions.

Restricted Remote materially reduces that same-user risk by moving the remote process to a separate standard-user token/profile. It is not a guarantee against every compromise: the restricted identity can still read the approved Git history and isolated task workspace, can execute user-level code as that restricted identity, and requires outbound network access for the Remote Desktop Commander control channel. Data intentionally exposed to a restricted task can therefore still be exfiltrated by a malicious authorized remote actor.

## Strong containment mode

`Install-RestrictedRemote.ps1` and `Activate-RestrictedRemote.ps1` implement the stronger tier as an opt-in mode. The installer creates a dedicated local standard account with a random credential protected by the interactive user's DPAPI, grants only the project/runtime access needed for contained operation, and keeps canonical Git metadata read-only. Restricted managed sessions use independent shared clones so new Git refs/objects and file edits stay outside the canonical repository until explicitly imported into a local review branch.

The launcher uses `-UseNewEnvironment`, a separate Windows profile, and a kill-on-close job object. The restricted child disables interactive Git credential prompting and uses dedicated MultiChat state/workspace roots. Emergency stop and uninstall paths revoke/remove the restricted authorization when possible.

The mode remains opt-in because initial setup requires administrator approval and tools such as GitHub authentication, Android device authorization, SDKs, or private package managers may need separate configuration for the restricted identity. Moving the portable MultiChat folder invalidates the previous restricted configuration rather than silently trusting stale path assumptions.
