# ClaudeBar

A macOS menu-bar app for tracking Claude Code usage across multiple Anthropic accounts.

- Shows session, weekly, and per-model usage for every signed-in account at once
- One-click account switching: ClaudeBar swaps the credentials Claude Code reads, so the next `claude` session runs on the account you picked
- Add accounts by running `/login` in `claude` — ClaudeBar detects and stores the new account automatically
- A "Next" badge recommends the account whose weekly limit resets soonest (never switches automatically)
- Usage comes straight from Anthropic's OAuth endpoints — no CLI processes are spawned
- Past sessions are indexed locally and scanned for estimated costs

## Installation

Download the notarized .app from the [releases page](https://github.com/vinnysaj/ClaudeBar/releases). Updates are delivered in-app via Sparkle.

### Keychain access

Claude Code stores its login in the macOS keychain. ClaudeBar reads and updates that item through the same system tool Claude Code itself uses (`/usr/bin/security`), so showing usage and switching accounts normally produces no keychain permission dialogs at all. If macOS does show one, click **Always Allow**. Stored credentials for non-active accounts live in ClaudeBar's own keychain item, which never prompts.

## Development

Build with `./build.sh` rather than bare `swift build`. The script signs the debug binary with a stable identity; without a stable signature, macOS treats every rebuild as a new app and re-asks for keychain permission each time.

