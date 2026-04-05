# ClaudeBar

A simplified version of [CodexBar](https://github.com/steipete/CodexBar) that strictly tracks Claude Code usage only. There are zero keychain prompts or disk access prompts. This is not really a fork - since there are some key differences, but the core logic is simple and mostly derived from a specific CodexBar setup:

- This app ONLY gets Claude usage from the Claude Code CLI
- There are zero direct calls to Anthropic's servers, reducing potential risk
- Usage is checked every 15 minutes
- Past sessions are indexed locally and scanned for estimated costs

If you're looking for a more fully-featured version of this app, check out [CodexBar](https://github.com/steipete/CodexBar)! It supports a lot of different providers. I built this because I needed something simple, since I only use Claude Code.

## Installation

Currently, there is no auto-update feature. Just head to the [releases page](https://github.com/vinnysaj/ClaudeBar/releases) and download the .app. It is notarized.

### Acknowledgements

ClaudeBar is derived from [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger, licensed under the MIT License. See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for details.
