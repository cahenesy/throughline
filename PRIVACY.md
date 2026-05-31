# Privacy Policy for throughline (Claude Code Plugin)

**Effective date:** 2026-06-01  
**Last updated:** 2026-06-01

throughline ("we", "us") is the author of the throughline Claude Code plugin. This Privacy Policy explains how the throughline plugin handles information when you install and use it inside [Claude Code](https://www.anthropic.com/claude-code).

throughline is **client-side software only**. It has no servers, no accounts, no telemetry endpoint, and no ability to phone home. All data processing happens on your machine under your control.

## 1. Information We Do Not Collect

The throughline plugin itself does **not**:

- Collect, transmit, or store any personal information, usage metrics, or analytics.
- Send any data to the plugin author, any marketplace, or any third party.
- Require or create user accounts.
- Access contacts, email, browser history, or other personal data outside the current git repository and Claude Code's own environment.
- Perform any network requests of its own (all model calls, GitHub operations, and package installs are performed by Claude Code, the `gh` CLI, or your project's own tooling).

## 2. Data the Plugin Processes Locally

throughline is a **governance overlay** for software engineering workflows. To do its job it must read and write files in **your current git repository** and interact with the Claude Code environment. This includes:

### 2.1 Files it reads
- Source code, tests, configuration, documentation, and git history in the repository you have open.
- `docs/PRD.md`, `docs/tdd/*.md`, `docs/adr/*.md`, `docs/.throughline-bootstrap.json`, and related design artifacts (when present).
- Output from your project's own test, typecheck, and lint commands (via `ci-checks.sh`).
- Git remotes, branch names, commit messages, and diff content.

### 2.2 Files it writes (all inside your repository unless noted)
- `docs/PRD.md`, `docs/tdd/NNNN-*.md`, `docs/adr/NNNN-*.md`, `docs/tdd/BLOCKERS.md`, `docs/tdd/LEARNINGS.md`, `docs/.throughline-bootstrap.json`, and supporting docs.
- Build logs and run-state records under `docs/tdd/.implement-logs/<timestamp>/` (this directory is added to `.gitignore` by the plugin).
- Small per-developer marker files under `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json` (see §4).

### 2.3 Draft persistence during interactive sessions
The `/prd-author` and `/tdd-author` skills write transient draft files to disk after every substantive user answer. These allow you to kill, compact, or reboot mid-interview and resume exactly where you left off. Drafts are overwritten by subsequent answers and are not retained after the skill completes normally.

### 2.4 Build logs and run-state records
When you run `/implement`, the detached runner writes:
- Full prompts sent to the LLM (including excerpts from your PRD, TDDs, ADRs, and the git diff being built).
- Model responses and tool-use transcripts.
- Command output from your project's test/lint/typecheck suite.
- Runtime verification observations.
- Per-step review findings (with severity and structural tags).

These logs are stored locally in your repository under a gitignored directory. They are intended for your debugging and audit trail. **They can contain sensitive code, design details, and (if present in your diffs) secrets.** Treat them with the same care as any other local log that may contain source material.

## 3. Model Calls and Third-Party LLM Providers

All language-model inference is performed by **Claude Code** using the provider and model(s) you have configured (typically Anthropic Claude models). throughline:

- Constructs prompts from your repository contents, TDDs, PRDs, git diffs, command output, and your interview answers.
- Sends those prompts to the LLM **through the Claude Code host process only**.
- Never makes direct API calls to Anthropic or any other provider.

Prompts sent to the LLM can contain:
- Your source code and tests.
- Design documents (PRD, TDDs, ADRs).
- Git diffs and commit messages.
- Output from your local development tools.
- Interview answers you type during `/prd-author` or `/tdd-author`.

**The content of those prompts is governed by Anthropic's privacy policy and your Claude subscription agreement**, not by this document. If you do not want certain files, secrets, or proprietary material sent to the LLM provider, do not include them in the repository while using throughline, or use Claude Code's permission controls / tool allowlists to restrict what the agent can read.

The security-reviewer agent (used during build gates) explicitly scans for secrets and credentials in the code under review and will flag them if found.

## 4. Local State and Repository Identity

throughline maintains two small markers so that `/bootstrap-project` and the SessionStart reconcile hook can be idempotent:

- **Repository marker** (committed): `docs/.throughline-bootstrap.json` — records the plugin version that last applied repo-level scaffolding, the detected language, and which bootstrap steps have run. This file lives in your git history.
- **Per-developer local marker**: `${CLAUDE_PLUGIN_DATA}/<repo-id>/local.json` — records the last plugin version seen by this developer on this machine and which local steps (e.g., dependency installation) have been completed.

The `<repo-id>` is a 12-character hex prefix of the SHA-256 of either:
- the `origin` git remote URL (preferred), or
- the absolute filesystem path of the repository root.

This identifier is derived locally and never leaves your machine. The `CLAUDE_PLUGIN_DATA` directory is managed by Claude Code and is local to your user account.

## 5. Git and GitHub Integration

throughline creates branches, commits, and (optionally) pull requests using **your** `git` and `gh` CLI tools. It never:

- Stores or transmits GitHub tokens.
- Makes direct REST or GraphQL calls to GitHub.
- Reads issues, comments, or other repository data beyond what `git` and the `gh` CLI surface in the context of the current working tree.

All GitHub interactions are authenticated with credentials you already have configured in your environment and are subject to GitHub's own privacy policy and your organization's GitHub policies.

## 6. Dependencies on Other Plugins

throughline is explicitly designed as a **thin governance layer** on top of Anthropic's official plugins:

- **superpowers** (provides test-driven-development, worktrees, verification mechanism, etc.)
- **pr-review-toolkit** (provides code review subagents)

When you install throughline, Claude Code will also install those two plugins from the `claude-plugins-official` marketplace (if not already present). Their data handling is governed by their own privacy policies and Anthropic's terms. throughline delegates engineering work to them rather than re-implementing it.

## 7. Your Choices and Control

You control what leaves your machine:

- **Do not commit** files you do not want in git (throughline respects your `.gitignore` and only adds the minimal `docs/tdd/.implement-logs/` entry itself).
- Use Claude Code's **permission mode**, tool allowlists, or OS-level sandboxing to restrict what the agent can read or execute.
- Delete `docs/tdd/.implement-logs/` at any time (it is already gitignored).
- Remove or never create the local marker directory under `CLAUDE_PLUGIN_DATA`.
- Run with `THROUGHLINE_REQUIRE_RUNTIME_VERIFY=0` or other documented escape hatches if you want to reduce certain observations.
- Use the "skip git" mode of `/implement` if you want to avoid branch/PR creation entirely.

## 8. Security

- throughline's own security-reviewer agent is deliberately included in the build gate precisely to catch secrets, credentials, and common injection patterns in the code being built.
- The plugin never attempts to exfiltrate data. Its bash scripts contain no `curl`, `wget`, or outbound network calls.
- All state writes are atomic (write-to-temp + `mv`) and best-effort; failures are silent where they cannot affect correctness.

Nevertheless, **you are responsible** for:
- Not putting secrets in files that the LLM will read.
- Reviewing the prompts and logs the plugin produces before they are committed or shared.
- Understanding that any code sent to an LLM provider is subject to that provider's data handling and retention policies.

## 9. Children's Privacy

throughline is a professional software-engineering tool intended for use by adults. It does not knowingly collect information from children under 13 (or the equivalent age in your jurisdiction).

## 10. Changes to This Policy

We may update this Privacy Policy to reflect changes in the plugin, Claude Code, or applicable law. When we do, we will update the "Last updated" date above. Material changes will be noted in the plugin's release notes or README.

Because the plugin is open source, you can always review the exact data-handling behavior in the source at:
https://github.com/<your-org>/throughline (or wherever you obtained the marketplace clone).

## 11. Contact

If you have questions about this policy or the data handling of the throughline plugin, open an issue in the repository or contact the author (Chris Henesy) via the contact method listed in the marketplace entry for the plugin.

---

**Summary for the impatient:**  
throughline is local-only client-side software. It reads and writes files in **your** git repo, sends prompts containing **your** code and design docs to **whatever LLM you have configured in Claude Code**, and stores small local markers and build logs under your control. It has no backend, no telemetry, and no ability to exfiltrate data. Treat the prompts and `docs/tdd/.implement-logs/` with the same sensitivity as any other artifact that may contain your proprietary source material.
