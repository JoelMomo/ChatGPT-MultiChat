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

All persistence canaries were removed immediately after the test.

The DPAPI result is important: a fully malicious but correctly authorized remote agent is not contained from secrets and files available to the signed-in user. UAC protects administrator-only locations, but it does not isolate one process running as the same user from that user's data.

## Hardening implemented

- Desktop Commander is pinned to the reviewed package version instead of using `@latest`.
- MultiChat no longer persists Desktop Commander stdout/stderr containing tool arguments and results.
- Local Desktop Commander telemetry is disabled.
- Remote authorization and Desktop Commander local state are protected by restrictive ACLs.
- Dashboard ONLINE state requires a persisted authorization record plus an established Remote Desktop Commander HTTPS connection.
- An emergency disconnect stops Remote Desktop Commander, revokes the current server-side device row and authentication session when possible, removes local authorization, and records only non-secret result metadata.
- Remote access disconnects when Windows is locked by default.
- Remote access disconnects after 30 minutes with no managed chats by default.
- Sensitive Desktop Commander local tool history is purged when remote access is stopped by default.
- Exiting MultiChat stops Remote Desktop Commander rather than leaving the remote agent behind.
- `SecurityTest.ps1` validates the security-critical configuration and local ACL state.
- The managed-chat prompt explicitly treats repository files, web content, issues, logs, terminal output, and downloaded artifacts as untrusted data and forbids external content from authorizing security-sensitive actions.

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

Remote Desktop Commander still runs as the interactive Windows user. Therefore a correctly authorized but hostile AI can potentially read, alter, delete, or exfiltrate data that the user account can access and can use user-level persistence mechanisms.

Command blocklists, path allowlists, MultiChat leases, and worktree rules are useful guardrails but are not a containment boundary against a deliberately hostile process running as the same Windows identity.

## Strong containment target

The next security tier is to run Remote Desktop Commander under a dedicated standard Windows identity with explicit NTFS access only to approved project roots and device resources. That would separate the AI's filesystem and DPAPI/credential boundary from the interactive user.

This stronger mode should be introduced as an opt-in compatibility-tested mode because Git credentials, Android authorization, repository paths, and other development tooling may need dedicated configuration for the restricted identity.
