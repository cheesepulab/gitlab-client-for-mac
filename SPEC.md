# GitLab Mac Client — Build Spec

Native SwiftUI macOS client for GitLab servers whose web UI is blocked but whose API and SSH git still work (for example a company GitLab reachable only over the VPN).

- **Web UI:** blocked.
- **SSH git:** works with the user's existing SSH key (`git@<domain>`).
- **REST API:** reachable. `curl -s https://<domain>/api/v4/version` returns `{"message":"401 Unauthorized"}`, so it only needs a personal access token (PAT).

The app uses the GitLab REST API (with a PAT) for GitLab data and actions, and local `git` over SSH for repository content and history. An AI CLI on the user's Mac handles work the server can't do, such as resolving merge conflicts.

This file is the original spec updated with what the design added: the domain comes first, several domains are supported, the app has a dark theme, the AI CLI settings and run screens are defined, and the app ships as a Homebrew cask. A second design round added the merge request Overview (approve, auto-merge, activity), a Details column for assignees and reviewers, a Pipelines tab and an Edit page. Design canvas: <https://claude.ai/artifact/1Ecg8umtMN2vWUNXG9dvqU>.

## Feature scope

| Feature | Source | Notes |
| --- | --- | --- |
| Add domain (first step) | Network checks | API `/api/v4/version`, SSH `ssh -T git@<host>`, HTTPS trust; several domains |
| Token setup, guide, update | Keychain + API | One token per domain; replaceable at any time from Settings → Domains |
| Repo list | API `GET /projects?membership=true` | Search, group filter, starred first |
| Repo view (files, branches, tags, README) | Local bare clone over SSH | API fallback until the clone exists |
| Git history (graph, commit detail, blame) | Local git | Paginated git log, lane-based graph |
| MR list (open / merged / closed) | API | Title, author, branches, pipeline, approvals, `detailed_merge_status` |
| MR detail (description, diff, commits) | API + local git | Diff from local `git diff` of `refs/mr/<iid>` |
| Merge | API `PUT …/merge` | Squash and delete-source-branch ticks in the merge box, reviewed `sha` |
| Auto-merge | API `PUT …/merge` (`auto_merge`), `POST …/cancel_auto_merge` | Offered while the head pipeline runs |
| Approve | API `POST …/approve`, `…/unapprove` | All tiers; required counts and rules only on Premium |
| Activity | API `…/discussions`, `…/notes` | Comments, replies, resolve threads, system history |
| Assignees and reviewers | API `PUT …/:iid`, `…/members/all` | Details column; several only on paid tiers (GraphQL tells which) |
| Pipelines | API `…/:iid/pipelines`, `/pipelines/:id/jobs`, `/jobs/:id/trace` | Cancel, retry, run; job cancel, retry, play; live log |
| Edit merge request | API `PUT …/:iid` | Title, draft, description, target branch, people, merge options |
| Clickable links | Local detection | URLs, `!12`, `#34`, `@name` in descriptions, comments and history |
| Rebase | API `PUT …/rebase` | Server-side; poll `rebase_in_progress` |
| Resolve conflicts with AI | AI CLI in a local worktree | User reviews the diff before the app pushes |
| AI CLI picker | Settings → AI CLI | Presets + custom command template, detection, test |
| Light and dark theme | System colors | Settings → General → Appearance: System, Light, Dark |

Out of scope: editing issues, labels and milestones, comments on diff lines.

## Architecture

A non-sandboxed SwiftUI app. Views talk to one `@Observable` `AppModel`; services are actors in the `GitLabClientCore` library, so they build and test without UI.

```
Package.swift
Sources/
  GitLabClientCore/      no UI; covered by swift test
    Models/              Domain, GitLabModels, GitModels, MergeStatus
    Services/            ProcessRunner + ShellEnvironment, TokenStore, GitLabAPIClient,
                         DomainChecker + SSHTokenGenerator, GitService
    Parsing/             git log / diff / ls-tree / blame parsers, GraphLaneBuilder
    AI/                  presets, command templates, prompts, ConflictResolver, CLI tester
  GitLabClient/          SwiftUI app
    App/                 entry point, AppModel, AppSettings, AppInfo, BuildDefaults
    Features/            Onboarding, Main (sidebar, domain switcher), Repo (code, history),
                         MergeRequests, AI (resolve sheet), Settings
    Shared/              components, Markdown, diff view
Tests/GitLabClientCoreTests
Resources/Info.plist     template filled in by scripts/build.sh
scripts/                 build, install, release, uninstall, signing helpers, icon
packaging/homebrew/      cask template
```

- **Platform:** macOS 14+, Swift 6 with strict concurrency, SwiftUI, Observation framework.
- **Build and distribution:** Swift Package Manager; `scripts/build.sh` assembles a universal `.app`, signs it ad-hoc (or with a Personal Team Apple Development certificate) with the Hardened Runtime. App Sandbox is off because the app needs `~/.ssh`, the ssh-agent socket and user-installed CLIs. Released as a zip on GitHub Releases and installed with `brew install --cask cheesepulab/tap/gitlab-client-for-mac`. Not notarized; the cask clears the quarantine flag.
- **Only `ProcessRunner` launches processes, and only `TokenStore` touches the Keychain.**

## Domains and tokens

### First launch: domain first

1. **Domain.** One field accepts a bare domain, any URL from the server, or an SSH clone URL. It is normalized (lower case, no trailing slash, `https://`, a leading `/gitlab` path kept). 600 ms after typing stops the app runs three checks:
   - API: `GET /api/v4/version` → 401 with JSON means GitLab is there and wants a token; 404 or HTML means not GitLab; timeouts and DNS errors mean unreachable.
   - SSH: `ssh -T -o BatchMode=yes git@<host>` → "Welcome to GitLab" passes; Permission denied, unknown host key or timeout are warnings (Continue stays enabled; clone, history and AI need SSH).
   - HTTPS certificate trusted.
   An "Advanced" disclosure sets a different SSH host and port. A domain that is already added offers "Switch to it".
2. **Token.** For the domain from step 1. A SecureField with reveal, then "How do I get a token?" (below). Connect calls `GET /user` and `GET /personal_access_tokens/self`. 401 = invalid or expired, 403 = missing scope, network error = host unreachable.
3. **Done.** User, token name, masked token, scopes, expiry with days left, Keychain location. "Add another domain" restarts at step 1; "Open GitLab Client" opens the main window.

### In-app guide: how to get a token

- **A. Generate it over SSH (GitLab 16.5+):** `ssh git@<host> personal_access_token gitlab-mac-client api,read_repository 30`. "Copy command" and "Generate for me"; the latter runs it through `ProcessRunner` with the user's SSH config and agent, extracts `glpat-[A-Za-z0-9_-]+`, and fills the field. The raw output is never logged.
- **B. Ask someone with web access** (User Settings → Access tokens).
- Scopes: `api` (merge, rebase, rotate; recommended), `read_api` (read-only; Merge and Rebase hidden with the reason shown), `read_repository` (optional; git uses SSH).
- Troubleshooting: Permission denied (publickey) → key not in the agent or not on the account; no token in output → server older than 16.5 or command disabled.

### Several domains

- The sidebar starts with a domain switcher: monogram, domain, @username. Its menu lists every domain with its status, plus "Add Domain…" (⇧⌘N, the same three-step flow as a sheet) and "Manage Domains…".
- Settings → Domains lists domains with +/−, Make default, and per-domain details and actions.
- Each domain has its own Keychain item (account = domain key) and its own clones folder, because project IDs repeat across servers.

### Updating a token (Settings → Domains)

| Action | Behavior |
| --- | --- |
| Replace | Paste a new token; validate it first; swap it into the Keychain only if valid |
| Generate via SSH | Option A, then replace |
| Rotate | `POST /personal_access_tokens/self/rotate`; store the returned token; hidden when the server returns 404 |
| Revoke | Confirmation, then `DELETE /personal_access_tokens/self`, then forget the token |
| Sign out | Delete the Keychain item only; the confirmation says the token stays valid on the server |

- Fewer than 7 days left: a dismissible banner in the main window with "Rotate now" and "Replace…".
- Any 401 opens a re-authentication sheet over the current window, keeping navigation, and retries the failed request once a valid token is saved.
- With no domain signed in, the app returns to the first-launch flow.

### Storage rules

- Keychain only: `kSecClassGenericPassword`, service = the app's bundle ID (`io.github.cheesepulab.gitlabclient`, set in `scripts/config.sh`), account = domain key. Never UserDefaults, files or logs.
- The UI shows only `glpat-••••` plus the last four characters.
- Domains (no secrets) are stored in UserDefaults.

## GitLab API client

`GitLabAPIClient` is an actor per domain on `URLSession` with async/await and `Codable` models (`convertFromSnakeCase`), at `<base>/api/v4`.

| Purpose | Method + path |
| --- | --- |
| Domain check | `GET /version` (no token) |
| Current user | `GET /user` |
| Token info | `GET /personal_access_tokens/self` |
| Rotate / revoke | `POST /personal_access_tokens/self/rotate`, `DELETE /personal_access_tokens/self` |
| Repo list | `GET /projects?membership=true&order_by=last_activity_at` (+ `starred=true`) |
| MR list / detail | `GET /projects/:id/merge_requests?state=…`, `GET …/merge_requests/:iid?include_rebase_in_progress=true` |
| MR commits / diffs / approvals / pipelines | `GET …/:iid/commits`, `…/diffs` (falls back to `…/changes`), `…/approvals`, `…/pipelines` |
| Merge / rebase | `PUT …/:iid/merge` (`squash`, `should_remove_source_branch`, `sha`), `PUT …/:iid/rebase` |
| Auto-merge | `PUT …/:iid/merge` with `auto_merge` and `merge_when_pipeline_succeeds`; `POST …/cancel_auto_merge`, falling back to `…/cancel_merge_when_pipeline_succeeds` on 404 |
| Approvals | `POST …/:iid/approve` (`sha`, optional `approval_password`), `POST …/:iid/unapprove` |
| Activity | `GET …/:iid/discussions`, `POST …/:iid/notes`, `POST …/discussions/:id/notes`, `PUT …/discussions/:id?resolved=` |
| Edit, people | `PUT …/:iid` (only changed fields; `[0]` clears a list), `GET /projects/:id/members/all?query=` |
| People limits | `POST /api/graphql`: `mergeRequest { allowsMultipleAssignees allowsMultipleReviewers }`; one each if it fails |
| Pipelines | `GET …/:iid/pipelines`, `POST …/:iid/pipelines`, `GET /projects/:id/pipelines/:pid`, `POST …/pipelines/:pid/cancel`, `…/retry` |
| Jobs | `GET …/pipelines/:pid/jobs?include_retried=true`, `POST /projects/:id/jobs/:jid/cancel`, `…/retry`, `…/play`, `GET …/jobs/:jid/trace` |
| Server version | `GET /version` (auto-merge wording: 17.0+ waits for every merge check) |
| Fallback browsing | `GET /projects/:id/repository/branches` (`search` for the target picker), `…/tree`, `…/files/:path/raw` |

Rules: `PRIVATE-TOKEN` read from the token provider per request; pagination through `X-Next-Page` as an `AsyncThrowingStream`; typed errors `.unauthorized`, `.forbidden(missingScope:)`, `.notFound`, `.conflict`, `.methodNotAllowed`, `.notAcceptable`, `.unprocessable`, `.server`, `.network`; a 401 asks for a new token once, then retries (except approve, where a 401 with a working token means the project wants the password); merging, auto-merge and approving pass the MR's `sha`.

Auto-merge sends both flags because servers before 17.11 only know `merge_when_pipeline_succeeds` and ignore `auto_merge`; sending only the new one to an old server would merge at once.

## Git layer over SSH

`GitService` shells out to the system git through `ProcessRunner`, inheriting `~/.ssh/config` and ssh-agent.

- Binary: resolved through the login shell (`/bin/zsh -lc 'command -v git'`); overridable in Settings → Git.
- Mirrors: one bare clone per project at `~/Library/Application Support/GitLabClient/repos/<domain>/<project-id>.git`, fetch refspecs `+refs/heads/*:refs/remotes/origin/*` and `+refs/merge-requests/*/head:refs/mr/*`. Fetch on open and on manual refresh.
- Worktrees: every mutating operation runs in a throwaway worktree under `~/Library/Caches/GitLabClient/worktrees/`, removed afterwards; leftovers from an interrupted run are removed at launch.
- History: `git log --date-order --format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1e`, 200 per page; lanes from parent hashes, continued across pages.
- Diffs: `git diff --patience refs/remotes/origin/<target>...refs/mr/<iid>`, parsed into files and hunks, rendered with line numbers and keyword coloring.
- Environment: `GIT_TERMINAL_PROMPT=0`, `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, `GIT_EDITOR=true`, so git never waits for input.
- Errors: Permission denied (publickey) and Host key verification failed map to messages with the fix.

## Merge request flows

`detailed_merge_status` decides the merge panel:

| Status | UI |
| --- | --- |
| mergeable | Merge, with the Squash commits and Delete source branch ticks (defaults from the project or Settings → Git); with a running pipeline, Set to auto-merge plus Merge now |
| need_rebase | Rebase (server-side), then poll every 2 s |
| conflict, broken_status | "Resolve with <CLI>" |
| ci_must_pass, ci_still_running | Reason, plus Set to auto-merge while the head pipeline runs |
| not_approved | Reason, plus Set to auto-merge while the head pipeline runs |
| draft_status, discussions_not_resolved, blocked_status, others | Reason (auto-merge as above, never for drafts) |
| checking, unchecked | Spinner; re-poll after 2 s |

- List per repo with Open / Merged / Closed; rows show `!iid`, title, branches, author, updated time, pipeline icon, approvals and a status pill.
- Detail tabs: Overview, Commits, Pipelines, Changes. Auto-refresh while the window is focused (30 s by default).
- Merge: 405/406 show GitLab's message; 409 (SHA mismatch) refreshes the MR and asks again. A rebase that ends with `merge_error` offers Resolve with AI.

### Overview

- Description rendered as Markdown with links: bare URLs, `!12`, `#34`, `group/project!12` and `@name` (not inside code). Merge requests of the open project, by reference or by URL on the same server, open in the app; everything else opens in the browser.
- Merge box: head pipeline (View pipeline switches tabs), approvals (Approve / Revoke approval; "Needs N more" and rules on Premium, "optional" on Free), conflicts and threads, then the action from the table above.
- Auto-merge set: "Set to auto-merge by <user>" with Cancel auto-merge.
- Approval password: when the project requires re-authentication, a sheet asks for the GitLab password, sends it in that one request and never stores it. SSO-only accounts can't approve from the app.
- Activity: discussions oldest first, filter All / Comments / History. Threads show replies, diff location, Reply and Resolve / Unresolve; system notes show as one line, with commit lists. Comment box at the bottom (⌘↩ posts).

### Details column

Toggle in the toolbar (remembered). Assignees and reviewers with a searchable member picker that saves as you pick; reviewers show Approved or Review requested. On servers that allow only one, picking replaces the current person. Reference and source branch with Copy.

### Pipelines tab

Pipelines of the MR (newest first) with Cancel or Retry per row and Run pipeline. The selected pipeline shows jobs by stage (latest attempt of each, stages in run order) with Cancel, Retry or Run per job, and the job log (ANSI colors reduced to tones, GitLab section markers removed, last 4000 lines). Polls every 4 s while something runs and the window is focused. Pipeline Retry reruns only the failed and canceled jobs, as on GitLab.

### Edit page

Pushed from the toolbar's Edit button. Title with Mark as draft (stored as the "Draft:" prefix; typing a prefix ticks the box), description editor with Write / Preview, formatting buttons, live link highlighting and a "Found" row of clickable links, target branch picker (the source branch can't change), assignees and reviewers, and the two "when merge request is accepted" ticks (squash locked when the project always or never squashes). The footer lists unsaved changes; Cancel asks before discarding them; Save sends only the changed fields.

## Resolve conflicts with AI

The AI CLI only edits files in a temporary worktree. The app does every git step and pushes only after the user approves.

1. Fetch; create a worktree on a temporary branch at `origin/<source>`; record the original SHA.
2. `git rebase origin/<target>` (or `git merge --no-ff`, per Settings → Git).
3. For each stop with conflicts: run the CLI with the task's prompt and the conflicted files; check no conflict markers are left (else stop, nothing pushed); `git add` the files; `git rebase --continue` (or `git commit --no-edit`). Up to 25 rounds.
4. Safety checks: no markers left, nothing in progress, branch tip changed.
5. Review: diff against the original branch, or the MR diff (`target...HEAD`); the run log.
6. Push only on the user's click: `git push --force-with-lease=refs/heads/<source>:<original-sha> origin HEAD:refs/heads/<source>`. Then remove the worktree and refresh the MR. Discard or Cancel terminates the CLI and removes the worktree.

The running screen shows live output, elapsed time against the time limit, the CLI, branch and worktree, and per-file status. The review screen shows the safety checks and the diff, with Discard and "Push to <branch>".

## AI CLI integration (Settings → AI CLI)

| Preset | Default command template |
| --- | --- |
| Claude Code | `claude -p "{prompt}" --permission-mode acceptEdits` |
| Codex CLI | `codex exec --full-auto "{prompt}"` |
| Gemini CLI | `gemini --yolo -p "{prompt}"` |
| Aider | `aider --yes --no-auto-commits --message "{prompt}" {conflicted_files}` |
| Custom | Any template with `{prompt}`; placeholders `{worktree}`, `{branch}`, `{target}`, `{conflicted_files}` |

- Detection: each preset's binary through the login shell; "Found at …", "Not installed", or "In use". "Choose…" picks a binary by hand.
- The template is split into arguments by the app (quotes group words); placeholders are filled per argument in one pass, and an argument that is exactly `{conflicted_files}` expands to one argument per file. No shell is involved.
- Prompt templates per task ("Rebase onto target", "Resolve merge conflicts"), editable with Restore default. Every prompt ends with a fixed line the user can't edit: "Never run git push. Never change files outside {worktree}."
- Test: runs the CLI once in an empty temporary folder asking it to reply OK, and shows the output and time.
- Timeout: 10 minutes by default, 1–60.

## Settings

| Tab | Contents |
| --- | --- |
| Domains | Domain list (+, −, Make default); per domain: web URL, SSH host and port, user, token name, masked token, scopes, expiry and days left; Rotate, Replace, Generate via SSH, Sign out, Revoke |
| AI CLI | Presets with detection, binary path, command template, prompts per task, timeout, Test |
| Git | git binary path, clone location, conflict strategy (rebase or merge), default merge options |
| General | Appearance (System, Light, Dark), MR auto-refresh interval, default MR tab, local clone size and Clear, version |

## Milestones

All implemented; each built and tested before the next.

- [x] M1 — Package skeleton, app lifecycle, packaging scripts, Homebrew cask template.
- [x] M2 — Domain step with checks, token onboarding and storage, SSH generation, validation.
- [x] M3 — Several domains, Settings → Domains, Replace / Rotate / Revoke / Sign out, expiry banner, 401 re-auth sheet.
- [x] M4 — Repo list with pagination, search, group filter, starred first.
- [x] M5 — ProcessRunner, GitService, bare clones, history with graph and commit detail.
- [x] M6 — File tree, file viewer with blame, branches, tags, README.
- [x] M7 — MR list and detail, status mapping, diff from local MR refs.
- [x] M8 — Merge and rebase, sheets, polling, error messages.
- [x] M9 — AI CLI settings, detection, Test, conflict resolution with review and push.
- [x] M10 — Overview: links, merge box with approvals and auto-merge, activity with comments, replies and resolve.
- [x] M11 — Details column with member pickers; Edit page.
- [x] M12 — Pipelines tab with stage graph, job actions and live log.

Unit tests cover git log, diff, tree and blame parsing, graph lanes, MR status mapping, token extraction and redaction, domain normalization and checks, command templates, API error mapping and retry (URLProtocol stubs), the full conflict flow and push lease on temporary local repositories, link detection and targets, system notes, job logs, stage grouping, draft titles, edit bodies, and the approve, auto-merge, GraphQL, update and trace calls.

## Rules for contributors

- Swift 6 strict concurrency; SwiftUI (AppKit only where SwiftUI lacks a control); `@Observable`, not `ObservableObject`.
- No third-party dependencies without asking.
- Never print, log or write a token anywhere except the Keychain; redact `glpat-` strings in captured output.
- Never run `git push` or a GitLab write call from code paths not triggered by an explicit user button.
- Don't use real company repos in automated tests; use URLProtocol stubs and temporary local repos.
- When a GitLab API detail is uncertain (for example rotation), handle the 404 rather than assuming it exists.
