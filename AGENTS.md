# Agent-ready project starter

This repo is a recipe, not an app. It packages a way of setting up a codebase so AI coding agents can work in it well and in parallel: context files, tools for agents, isolated environments per worktree, reusable skills, and an orchestration workflow. [README.md](README.md) explains the approach for people. `starter/` holds the files that get copied into a project and filled in.

## If you were asked to set up another project with this

Follow [ADOPTING.md](ADOPTING.md) from step 1. It is the procedure: survey the target repo, copy `starter/`, fill every `FILL:` marker with what you learn, and leave the project's own conventions intact. `scripts/check-fill-markers.sh <target>` is its completion check.

The rules that matter most while you adopt:

- **The target project's facts come from the target project.** Read its code, scripts, CI, and docs before you ask the person anything, and ask only for decisions and for facts no file holds.
- **Fit the recipe to the project, not the project to the recipe.** Keep the principles (in [README.md](README.md)), and translate each mechanism into the target's own stack, task runner, and branch names. Drop what has no counterpart, and say so.
- **Context changes are reviewed by a person.** Put the adoption on its own branch and open a pull request. Do not push it to the target's main or integration branch.

## If you are changing this repo

- `starter/` is a template. Everything project-specific in it is a `FILL:` marker: `<!-- FILL: ... -->` for a block instruction in Markdown, `[[FILL: ...]]` inline, and `# FILL:` or `// FILL:` in code. Keep it free of any real project's names.
- The skills under `starter/.agents/skills/` that have no `FILL:` marker are meant to be copied unchanged. Keep them generic.
- Write for agents with the [writing-for-agents](starter/.agents/skills/writing-for-agents/SKILL.md) skill and for people with the [writing-for-humans](starter/.agents/skills/writing-for-humans/SKILL.md) skill.
- Run the self-tests under `starter/tooling/**/test/` after changing a script.
