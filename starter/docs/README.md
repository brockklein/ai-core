# [[FILL: project name]] docs

Read the documents below when their scope matches your task.

<!-- FILL: Each entry is a link plus what it covers, written as the topics a task would name, so an agent can match its task to the entry without opening the file. This index is read at the start of every session; the files are not. -->

## Internals

Decisions, constraints that span components, and traps the source alone does not explain. Read these before changing the areas they cover.

<!-- FILL: One entry per file in docs/internals/. Write a file here only for a decision or trap that spans components. Local behavior belongs in a comment beside the code, and formulas belong to the code and its tests. -->

<!-- FILL: Entry shape: - [Local data](./internals/local-data.md) — sync rules and write validation, offline merges, and streaks. -->

## Runbooks

Use these when performing the named operation.

- [First-time setup](./operations/first-time-setup.md) — setting up a new development environment, local environment files, and [[FILL: other configuration that git does not hold]].
- [[FILL: deploy, release, restore, and other runbooks, wherever they live, each with the operations it covers]]
