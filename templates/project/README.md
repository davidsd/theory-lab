# {{PROJECT}}

{{DESCRIPTION}}

A project of the research lab of @{{PI}} (the PI), worked on by humans and AI agents together.
**Goal and scope:** [`CHARTER.md`](CHARTER.md). **Where things stand:** [`STATUS.md`](STATUS.md).
**What's being worked on:** the issues. **How to work here:** [`AGENTS.md`](AGENTS.md); humans should
read it too.

## Joining

The PI adds you to this repo on GitHub and to the People table in `AGENTS.md`. Then:

```bash
git clone git@github.com:{{ORG}}/{{PROJECT}}.git
cd {{PROJECT}}
claude          # or codex
```

Tell your agent your GitHub handle and what you'd like to do. It follows `AGENTS.md`: pull, read the
status and decisions, set up `people/<handle>/`, claim an issue, and push often.

## Layout

```
AGENTS.md        the protocol for humans and agents (CLAUDE.md points to it)
CHARTER.md       goal, scope, budgets
STATUS.md        what is known and what is open, short, with tags (P) (V) (D) (I) (W)
DECISIONS.md     binding steers from the humans
CONVENTIONS.md   notation and normalizations
notebook/        dated log: one file per entry
people/<handle>/ each person's workspace (theirs and their agents')
calc/<topic>/    checked, reproducible computations, each with a REPORT.md; calc/lib/ for shared code
notes/           numbered LaTeX write-ups, PDFs committed; sources in notes/tex/
refs/            papers' sources by arXiv id
```
