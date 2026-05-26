# Skills

A portable skill library for AI coding agents. Clone it once, add your skills, then symlink them into any project with a single command.

Works with **Claude Code**, **Codex**, and **Pi** — `link.sh` fans out symlinks so each agent finds skills in its expected location.

## Quick start

```bash
# Clone to ~/.skills
git clone git@github.com:codesoda/skills.git ~/.skills

# Add a skill (a folder with a SKILL.md)
mkdir -p ~/.skills/.agents/skills/my-skill
cat > ~/.skills/.agents/skills/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: Does something useful
---
# my-skill
Instructions for the agent go here.
EOF

# Link it into a project
cd ~/my-project
~/.skills/link.sh my-skill
```

## Folder layout

```
~/.skills/
├── link.sh                          # Distributes skills into projects
├── skills-lock.json                 # Tracks installed skills (gitignored)
└── .agents/
    └── skills/
        ├── meta-skill/              # On-demand skill loader (ships with repo)
        │   └── SKILL.md
        ├── my-skill/                # Your skills go here
        │   └── SKILL.md
        └── another-skill/
            └── SKILL.md
```

When you run `link.sh` from a project directory, it creates this structure inside the project:

```
my-project/
├── .agents/
│   └── skills/
│       └── my-skill -> ~/.skills/.agents/skills/my-skill
├── .claude/
│   └── skills -> ../.agents/skills
├── .codex/
│   └── skills -> ../.agents/skills
└── .pi/
    └── skills -> ../.agents/skills
```

`.agents/skills/` is the canonical location. The `.claude/`, `.codex/`, and `.pi/` folders are symlinks so each agent platform discovers skills at its expected path.

## link.sh

### Auto mode (default)

Symlinks skills directly into the project so agents auto-discover them:

```bash
cd ~/my-project
~/.skills/link.sh my-skill another-skill
```

### Meta mode (`--meta`)

Registers skills in a `meta-skills.json` file instead of symlinking them. The agent loads them on demand when you invoke `/<skill-name>`:

```bash
cd ~/my-project
~/.skills/link.sh my-skill another-skill --meta
```

This is useful when you have many skills but don't want them all loaded into every session. The `meta-skill` (auto-linked when you first use `--meta`) reads the registry and loads the requested skill at runtime.

### When to use which

| Mode | Agent sees it in skill list? | Loaded when? | Best for |
|------|------------------------------|--------------|----------|
| Auto | Yes | Every session | Core skills you always want available |
| Meta | No (until invoked) | On demand via `/<name>` | Large libraries, situational skills |

## Writing a skill

A skill is a folder containing at least a `SKILL.md` file:

```
my-skill/
├── SKILL.md        # Required — agent instructions
├── references/     # Optional — supporting docs the skill can read
└── evals/          # Optional — test cases
```

The `SKILL.md` frontmatter tells the agent when and how to use the skill:

```markdown
---
name: my-skill
description: One-line description used for trigger matching
metadata:
  version: 1.0.0
---

# my-skill

Instructions for the agent go here.
```

The `description` field is important — agents use it to decide whether to trigger the skill for a given user request.

## Collections

A skill folder without a top-level `SKILL.md` that contains sub-folders with their own `SKILL.md` files is treated as a **collection**. Collections can only be auto-linked (not meta-registered):

```
research/
├── deep-dive/
│   └── SKILL.md
└── quick-scan/
    └── SKILL.md
```

```bash
~/.skills/link.sh research    # Links the whole collection
```

## The meta-skill

The `meta-skill` ships with this repo. It's an on-demand loader that resolves `/skill-name` invocations for skills registered via `--meta` mode. When you invoke a skill that isn't in the current session's skill list, the meta-skill reads `.agents/skills/meta-skills.json`, finds the skill's path, loads its `SKILL.md`, and follows the instructions as if the skill had been loaded normally.

You don't need to link the meta-skill manually — `link.sh --meta` auto-links it the first time you register a meta skill.

## License

MIT
