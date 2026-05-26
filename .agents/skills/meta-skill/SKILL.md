---
name: meta-skill
description: On-demand loader for skills that are registered but not currently exposed in the available skills list. Triggers when the user invokes `/<skill-name>` for a skill that is NOT in the available skills list, OR when the user asks in natural language to "use the X skill", "run the X skill", "load the X skill", or "invoke the X skill" and X is not currently available. Reads `.agents/skills/meta-skills.json`, resolves the skill's registered path, then reads its `SKILL.md` and follows the instructions inside as if the skill had been loaded normally. Do NOT trigger when the named skill IS already loaded (invoke it directly via the Skill tool). Do NOT trigger when the user is asking generally about what skills exist (answer using meta-skills.json without loading anything).
metadata:
  version: 1.0.0
---

# meta-skill — on-demand skill loader

You resolve explicit skill invocations for skills that are registered in this project but not currently exposed in the session's available skills list.

## When to act

Trigger this skill ONLY when both are true:

1. The user is invoking a specific, named skill — either as `/<skill-name>` or in natural language ("use the X skill", "run the X skill", "load the X skill", "invoke the X skill").
2. That skill name is NOT in the list of currently available skills shown in the system reminders.

If the requested skill IS already in the available skills list, invoke it directly via the Skill tool — do NOT go through this meta-skill.

If the user is asking which skills exist or what's available, answer that directly using the meta-skills.json content as input, but do not load any skill.

## What to do

1. **Identify the requested skill name.** Strip a leading slash, articles, and noise words like "the", "skill", "use", "run", "load", "invoke". If you are not confident of the exact name, ask the user to disambiguate before proceeding.

2. **Locate the registry.** Read `.agents/skills/meta-skills.json` from the project root. If the current working directory is not the project root, walk upward until you find a directory containing `.agents/skills/meta-skills.json`. If no registry exists in any parent directory, tell the user: "No meta-skills registry exists in this project. Register a skill with `~/.skills/link.sh <skill-name> --meta` from the project root."

3. **Look up the skill.** Parse the JSON. The shape is `{ "version": 1, "skills": { "<name>": { "path": "<abs-path-to-SKILL.md>", "source": "<abs-path-to-skill-dir>", "registeredAt": "..." } } }`. If `skills[<name>]` is missing, list the registered names from the JSON and tell the user which ARE available.

4. **Load the skill's SKILL.md.** Read the file at the entry's `path` (an absolute path). Treat its contents as if the harness had just loaded that skill.

5. **Follow the loaded instructions.** Apply the skill's body to the user's actual request. If the skill body references sibling files (e.g. `references/foo.md`, `evals/bar.md`), resolve them relative to the SKILL.md's directory (i.e. the `source` field of the registry entry, or `dirname(path)`).

## Notes

- The `path` field is an absolute filesystem path. Do not try to resolve it relative to the project.
- After loading, behave exactly as if the skill had been pre-loaded — honor its triggers, refusals, and required-context rules.
- If the user's request is missing inputs the loaded skill needs, ask for them after loading (so questions are informed by the skill's contract), not before.
- If a skill's `path` no longer exists on disk, tell the user the registry is stale and suggest re-running `~/.skills/link.sh <skill-name> --meta` to refresh it. Do not silently fall back to a different skill.

## Example

User: "use the pr-create skill to open a PR for this branch"

- `pr-create` is not in this session's available skills list.
- Read `.agents/skills/meta-skills.json` from the project root.
- Find `skills["pr-create"]`. Get its `path` (e.g. `/Users/chrisraethke/.skills/.agents/skills/pr-create/SKILL.md`).
- Read that file.
- Execute its instructions against the user's request (open a PR for the current branch).
