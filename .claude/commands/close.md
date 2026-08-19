---
description: Close the session — summarize, save to engram, then commit + push
---

Orchestrate the session close in this order. You coordinate; the subagents do
the heavy lifting.

Optional focus (may be empty): $ARGUMENTS

## 1. Write the summary

Write the session summary from the actual history of this conversation — you are
the only one who has it. Five sections:

- **Goal** — what the session set out to do.
- **Discoveries** — findings, gotchas, root causes. The *why*, not just the what.
- **Accomplished** — what actually got done. If something is half-finished, say so.
- **Next Steps** — what comes next, including known blockers.
- **Relevant Files** — concrete paths that were touched or that matter.

If `$ARGUMENTS` carries a focus (e.g. `/close just the healthcheck work`), scope
the summary to that topic.

## 2. Show it

Show the summary to the user **before** persisting anything.

## 3. Persist to engram

Launch the `session-closer` subagent (`subagent_type: "session-closer"`), passing
it the summary **verbatim** in the prompt. It cannot see the conversation: that
text is its only source of truth, so do not trim or paraphrase it.

If it returns items pending the user's judgment, do not resolve them yourself:
keep them for the final report.

## 4. Commit

Launch the `git-committer` subagent (`subagent_type: "git-committer"`) for the
semantic commit and the push. Do not run `git commit` yourself.

`git-committer` already stops on its own if the current branch is `master`/`main`,
and never stages `.env` or `*.local.json`.

**If step 3 failed, still do step 4** and say so. Losing the summary should not
also cost the commit.

## 5. Report

Close with:

- What was saved to engram (and what was skipped as a duplicate).
- Branch, sha and subject of the commit, and whether the push worked.
- What is left pending: memory decisions that need the user's judgment, files the
  agent did not commit and why, blockers for the next session.
