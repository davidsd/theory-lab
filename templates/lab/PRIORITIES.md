# What the PI wants to hear about

Every result, question and problem gets one of four levels. Leads assign them; the director tunes this
file from the PI's feedback, adding dated examples at the end; the PI edits it directly too. The lists
below are starting guesses, to be replaced by what the PI actually says.

| Level | Where it goes | Who waits |
|---|---|---|
| log | The notebook only | Nobody |
| digest | The director's daily digest | Nobody |
| ask | An issue labeled `inbox` + `ask`, assigned to @{{PI}}, stating the default you'll follow | Nobody: carry on with the default |
| interrupt | An issue labeled `inbox` + `interrupt`; the watchdog pushes it to the PI's phone | Only work that depends on it |

## Interrupt (rarely: a few times a week across the whole lab)

- A verified result that changes what the lab should do: a large speedup, a new bound or method that
  works, a known result shown wrong. Performance headlines must name the baseline: say whether the
  improvement is over the PI's actual production setup (the same code line, settings and layout the PI
  uses) or over a baseline the lab built itself, and label measurements of other setups explicitly.
- A blocker on a project's main line when there is nothing else useful to do.
- Something that looks wrong: a result contradicting an earlier verified one, lost data, runaway spending.
- An agent running below the agreed model or effort, or any other change that weakens research quality.
  Say what was observed, what was required, and the remedy.

## Ask

- A choice between research directions that the charter doesn't settle.
- Spending beyond the project's budget, or code ready for one of the PI's repos (with the compare link).
- New project proposals (the director forwards the good ones).
- Small cluster jobs held only by a daily limit don't need a question: they are released automatically
  once they fit again.

## Digest

- Progress on each project, verified results of moderate size, negative results worth knowing,
  problems the agents solved themselves.
- In exploratory projects, what a line of work taught about the method counts as progress, even when
  it stopped at a missing input. Report the lesson, not only the delay.
- Soft resource warnings: e.g. a scratch file count above the center's nominal limit while file creation
  still works. Hard limits (bytes near a quota, writes failing) are alerts.

## Log

- Routine runs, intermediate steps, failed attempts already explained by the notebook.

## The PI's feedback

The director adds dated entries here: the item, what the PI said, and how the rules above changed.
