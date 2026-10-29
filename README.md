# GitLab Client

A native macOS client for GitLab servers whose web UI you can't reach, but whose API and SSH still work. Browse repositories and history, review and merge merge requests, and let an AI CLI on your Mac resolve merge conflicts, with your review before anything is pushed.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

> **Not an official GitLab product.** GitLab Client is an independent open-source project. It isn't affiliated with, endorsed by or supported by GitLab Inc. It only talks to GitLab servers through their public REST API and git over SSH. GitLab is a trademark of GitLab Inc.

## Features

- **Domain first.** Add your GitLab domain; the app checks that its API, SSH and HTTPS certificate answer before it asks for a token.
- **Several domains.** Switch between servers from the sidebar, each with its own account and token.
- **Tokens without the web UI.** Generate a personal access token over SSH (GitLab 16.5+), paste one, rotate, replace or revoke it. Tokens live only in the Keychain.
- **Repositories.** Search, group filter, starred first. Files, branches, tags, README and blame at any branch.
- **History.** Paginated `git log` with a lane graph and the diff of each commit.
- **Merge requests.** Open, merged and closed lists; description, commits and changes; Merge (squash, delete source branch) and server-side Rebase, driven by GitLab's `detailed_merge_status`.
- **Review without the web UI.** Approve or revoke, set or cancel auto-merge, comment, reply and resolve threads. Change assignees and reviewers from the Details column, or edit the title, draft state, description, target branch and merge options on the Edit page.
- **Pipelines.** Every pipeline of a merge request with its jobs by stage and the live job log; cancel, retry or run pipelines and jobs.
- **Clickable links.** URLs, `!12`, `#34` and `@name` in descriptions and comments are links; merge requests of the same project open in the app.
- **Resolve conflicts with AI.** Claude Code, Codex CLI, Gemini CLI, Aider or your own command resolves conflicts in a throwaway worktree. You review the diff; the app pushes with `--force-with-lease` only when you click Push.
- **Light and dark mode**, following macOS or set by hand.

## Install

Requires macOS 14 Sonoma or later, `git` (the Xcode command line tools) and an SSH key on your GitLab account.

### Homebrew (recommended)

```bash
brew install --cask cheesepulab/tap/gitlab-client-for-mac
```

The app isn't notarized by Apple, so the cask clears the download quarantine flag after installing. You can read [the cask](packaging/homebrew/gitlab-client-for-mac.rb.template) before installing.

### Build from source

Needs Xcode 16 or later (or its command line tools with Swift 6).

```bash
git clone https://github.com/cheesepulab/gitlab-client-for-mac.git
cd gitlab-client-for-mac
scripts/install.sh
```

`install.sh` builds the app and copies it to `~/Applications`. Apps you build yourself aren't quarantined, so they open without a warning.

## Getting started

1. Enter your GitLab domain, for example `gitlab.example.com`, or paste any URL or SSH clone URL from it. Wait for the three checks.
2. Get a token. **Generate for me** runs `ssh git@<domain> personal_access_token gitlab-mac-client api,read_repository 30` with your SSH key. Or paste one an admin made for you. Give it the `api` scope; `read_api` gives a read-only app.
3. Pick a repository. The first time, the app makes a bare clone over SSH; later opens only fetch.
4. To use AI conflict resolution, pick a CLI in **Settings → AI CLI** and press **Test**.

## How it works

- **GitLab data** comes from REST API v4 with the `PRIVATE-TOKEN` header. A 401 opens a sign-in sheet over the window and retries the request once a new token is saved.
- **Code and history** come from your system `git`, so `~/.ssh/config`, `ssh-agent` and Keychain SSH keys just work. Each project has one bare clone in `~/Library/Application Support/GitLabClient/repos/<domain>/<project-id>.git`, fetching branches and merge request heads (`refs/merge-requests/*/head`).
- **AI resolution** runs in a temporary worktree under `~/Library/Caches/GitLabClient/worktrees`. The app replays the branch (`git rebase` or `git merge`, per Settings → Git), runs the CLI on the conflicted files only, checks that no conflict markers are left, continues the rebase itself, and shows you the diff. Your own checkouts are never touched. The CLI command is split into arguments by the app; no shell sees the prompt.
- **Tokens** are generic passwords in the Keychain, one per domain (service `io.github.cheesepulab.gitlabclient`). The UI only ever shows `glpat-••••` plus the last four characters, and token-like strings are redacted from any process output.
- **GitLab tiers.** Approving, auto-merge, comments, pipelines and editing work on every tier. Required approval rules and several assignees or reviewers per merge request are Premium features; on GitLab Free the app shows approval as optional and picking a person replaces the current one.

## Good to know

- The app is not sandboxed (it needs `~/.ssh`, the ssh-agent socket and your CLIs) and is signed ad-hoc with the Hardened Runtime.
- **Keychain prompt after an update:** each ad-hoc build has a new signature, so macOS may ask once more for access to the saved token.
- **Uninstalling:** `brew uninstall --zap` removes clones and settings, but not tokens. Sign out or revoke them in Settings → Domains first, or run `scripts/uninstall.sh --data`.

## Development

```bash
swift build                 # debug build
swift test                  # parsers, API error mapping, git and AI flows on temporary repos
swift run GitLabClient      # run without packaging
scripts/build.sh            # dist/GitLab Client.app, universal, signed
scripts/release.sh 0.1.0    # tests, build, zip and the Homebrew cask; uploads nothing
```

Settings that differ per machine (such as signing with your Apple Development certificate) go in `scripts/config.local.sh`; see `scripts/config.local.sh.example`.

Debug builds can draw their own windows to PNG files, which helps check screens without Screen Recording permission: `GLC_SNAPSHOT=<folder>` (and optionally `GLC_APPEARANCE=dark`, `GLC_DEBUG_DOMAIN=gitlab.example.com`). See `Sources/GitLabClient/App/DebugSnapshot.swift`.

Against a local mock server only (`GLC_DEBUG_SEED=http://127.0.0.1:<port>` with a test token in `GLC_DEBUG_TOKEN`, which replaces the saved domains for that run), `GLC_DEBUG_ACTIONS`, `GLC_DEBUG_PIPELINE_ACTIONS` and `GLC_DEBUG_EDIT` press the merge request, pipeline and Edit page buttons so a snapshot shows the result. Never point them at a real server. None of this is in release builds.

See [SPEC.md](SPEC.md) for the full specification.
