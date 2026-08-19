---
description: Semantic commit and push to the current remote branch
---

Use the `git-committer` subagent (Agent tool, `subagent_type: "git-committer"`) to
analyze the repo state, write a semantic commit message, commit, and push to the
current remote branch.

Extra context from the user (may be empty): $ARGUMENTS

If context is provided, pass it to the agent to use as the commit's scope or reason.

Do not make the commit yourself: always delegate to the subagent.

When it finishes, report to the user the branch, the commit sha and subject, and
whether the push worked.
