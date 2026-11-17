---
name: writing-for-humans
description: Writing text a person reads and acts on. Use before writing anything a human will scan between other work, such as a commit message, an issue or comment, a pull request description, release notes, or a wizard's messages.
---

# Writing for humans

The reader is a person scanning between other work. Make the text fast to read and hard to misread. Two habits carry most of it: lead with what the reader needs, and write in **ASD-STE100 Simplified Technical English**.

## Lead with what the reader needs

Open with what a person needs to decide or act: what happened, what it affects, what call is owed and by whom. A reader who stops after the opening should still be able to act. The opening is not a shortened copy of the detail; it serves a different reader. In a commit message, the subject and first paragraph carry it: the symptom, the cause, the fix.

Put the evidence after it: references, log lines, command output. Quote them verbatim, never rephrased for readability.

## QA handoff

A QA handoff hands finished work to a person to check. Release notes for a test build and the recap of a milestone shipped to a shared test environment both take this shape, and the issue-tracker skill's QA comment adapts it:

<!-- FILL: Name this project's QA surfaces (e.g. "a deploy to staging covers the API and web app; a TestFlight build covers the iOS app"), and the release-notes variable or file a QA handoff goes into, if any. Delete this section if no person checks work before release. -->

```
Focus this build: <one sentence: what changed for the person checking it>

What changed, and where to check it:
- <Area (plain gloss)>: <action>. Expect <result>.

Not checkable here: <area>: <what verifies it, and when>. Skip it.
```

- **Name each area by its glossary term plus a plain gloss.** "Checkout (the payment screen after the cart)", not "checkout" alone.
- **Give each step one action and the result to expect**, so the reader can tell a pass from a fail.
- **Route each area to the surface that verifies it.** [[FILL: which surface verifies which area, e.g. "A promotion to `staging` deploys the API and the web app. A staging build covers the mobile app."]] A docs-only change needs no QA.
- **Where the surface cannot exercise an area, say so**, name what does verify it and when, and tell the reader to skip it.
- **Cover only what changed since the last handoff**, and name the handoff it extends.
- **Keep setup out of the tester text.** Build, branch, and rig setup go in the recap's agent part, never in the release notes.

## Simplified Technical English

These are habits, not a checklist to recite:

- **One idea per sentence.** Split a sentence that carries two.
- **Short sentences.** Up to 20 words for an instruction, 25 for description.
- **Active voice, and name the actor.** "The worker sends the push", not "the push is sent".
- **Simple tenses.** Present, past, or future simple.
- **Start an instruction with its verb.** "Move the issue to In Progress."
- **Keep the articles.** "Set the flag", not "Set flag".
- **One word, one meaning, every time.** Pick the term and repeat it, even when repetition feels clumsy. A synonym reads as a second thing. Use the glossary's term (`AGENTS.md` → Glossary, then [`docs/glossary.md`](../../../docs/glossary.md)); when a term that will recur is missing, add a row there instead of coining it.
- **Noun clusters of three words at most.** Break longer ones with a preposition: "the auth token for the app", not "the app auth token store key".
- **Say what to do.** A prohibition makes the reader hold the wrong action in mind, so give the target action. Keep "do not" for a real hazard.
- **Short paragraphs.** Up to six sentences.

## Where it stops

This governs written artifacts, not conversation. Simplified Technical English was built for procedural documentation read under pressure, where the reader cannot ask a follow-up. A conversation is interactive and self-correcting, and much of its value is in confidence levels, what was verified against what was inferred, and why one option beats another: the things a 20-word cap and one-word-one-meaning flatten. Keep the project's terms in conversation; leave the rest here.
