# Security model

- GPT Switcher is local-only and makes no network requests of its own.
- All accounts share the official default local workspace (`~/.codex`) and Electron data directory so projects, threads, and task history remain continuous.
- Each account keeps an official `auth.json` snapshot in its private GPT Switcher directory. Switching performs an opaque, atomic file copy to the official active path; the app never decodes, displays, or logs credential contents.
- Usage refresh starts the ChatGPT bundle's local Codex App Server with a private temporary `CODEX_HOME` and calls only `account/rateLimits/read`. GPT Switcher retains plan type, usage percentages, window durations, reset timestamps, and fetch time in memory; backend account IDs are discarded.
- If the local App Server refreshes OAuth state during a usage request, the resulting official `auth.json` is copied back opaquely to that account slot before the temporary directory is deleted.
- Passwords, browser cookies, Local Storage, Keychain items, and project/chat databases are never copied by GPT Switcher. Usage queries do not read conversations.
- Managed directories use mode `0700`; copied auth files and configuration use mode `0600`.
- Before the first managed activation, the pre-existing official auth file is copied once to `migration-backup/original-auth.json` for recovery.
- Configuration and logs contain only profile IDs, display names, shortcuts, paths, lifecycle events, and preferences.
- Account deletion is restricted to an exact, non-symlink child of the GPT Switcher profiles directory.
- The shared official ChatGPT/Codex directories are never deletion targets.
- Profile IDs are restricted to lowercase ASCII letters, digits, and hyphens to prevent path traversal.

This model intentionally differs from GPT Switcher 1.0. Full Profile isolation prevented accounts from sharing local projects and threads. Version 1.2 isolates only the login snapshot, leaves the workspace shared, and reads rate-limit metadata through the bundled local App Server.
