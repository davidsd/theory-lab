# Notebook

The project's dated log: what was tried, what came out, and where the details are. One file per
entry, so that many people and agents can add entries at once without conflicts. Name it
`YYYY-MM-DD-<handle>-<issue>-<short-name>.md`, e.g. `2030-01-15-lab-12-solver-precision-scan.md`.
Never edit someone else's entry: to correct one, write a new entry that refers to it.

Each entry starts with a line `<handle> (human|agent), YYYY-MM-DD HH:MM, issue #<n>`, then:

- **Question:** what it tries to find out.
- **Setup:** code (repo, branch, commit), inputs and parameters, machine, the exact commands.
- **Result:** numbers with uncertainties, tagged (P) (V) (D) (I) (W); paths to plots.
- **Check:** how the result was checked, and how it could still be wrong.
- **Data:** where the outputs are (a `calc/` folder, the project's data folder, cluster paths, ...).
- **Next:** what it suggests doing.

Negative results get entries too.
