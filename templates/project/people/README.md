# Workspaces

Each person has a folder `people/<github-handle>/`, used by them and by the agents working for them;
the lab's agents use `people/lab/`. Everything here is committed and pushed, so others can look, but
only its owner edits it.

Setting up a new workspace (an agent does this on its first session):

```
people/<handle>/
  README.md      who you are and what you're working on now (1–5 lines, kept current), with pointers
  <topic>/       one folder per line of work, each with a short README or REPORT.md
  scratch/       git-ignored: local files that should never be committed
```

Several agents working for the same person at once use separate `<topic>/` folders; the lab's
workers use `people/lab/<issue>-<short-name>/`.

When something here is checked and useful to others, promote it to `calc/<topic>/` or `notes/` (see
`AGENTS.md` §3) and write a notebook entry. Anyone may read anyone's workspace; don't edit someone
else's: copy into your own instead.
