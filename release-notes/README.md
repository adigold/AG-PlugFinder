# Release notes

One file per release: `release-notes/<version>.md`, for example `0.2.0.md`.
`scripts/release.sh <version>` puts these lines in the update the app shows.

- One change per line, starting with `- New:`, `- Improved:` or `- Fixed:`.
- Describe what you get, never how it works (no library, vendor or model names).
- No em dashes or double dashes. The release script refuses files that break this.
