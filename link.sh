#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_HOME="$SCRIPT_DIR/.agents/skills"
META_SKILL_NAME="meta-skill"
SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME <skill-name> [<skill-name>...] [--meta]
       $SCRIPT_NAME --list

--list:
  Print the skills available in the source library (with descriptions) and
  exit. Does not require a skill name or a project directory.

Without --meta (auto install):
  Symlinks each named skill into ./.agents/skills/<name> so the agent can
  auto-trigger it. Also ensures ./.claude/skills and ./.codex/skills are
  folder-level symlinks pointing at ./.agents/skills.

With --meta (on-demand install):
  Registers each named skill in ./.agents/skills/meta-skills.json instead
  of symlinking it directly. The meta-skill itself is auto-linked so it
  can resolve explicit skill invocations at runtime.

Source skills live in $SKILLS_HOME
EOF
  exit 1
}

err() { echo "error: $*" >&2; exit 1; }

is_collection() {
  local p="$1"
  [ -d "$p" ] && [ ! -f "$p/SKILL.md" ] && find "$p" -mindepth 2 -maxdepth 2 -name SKILL.md -print -quit 2>/dev/null | grep -q .
}

# Pull the first line of the `description:` out of a SKILL.md's YAML
# frontmatter. Handles plain values (`description: text`), quoted values, and
# block scalars (`description: |` / `>`) whose text sits on indented lines below.
extract_description() {
  awk '
    /^---[[:space:]]*$/ { fence++; if (fence >= 2) exit; next }
    fence != 1 { next }
    !indesc && /^[[:space:]]*description:/ {
      val = $0
      sub(/^[[:space:]]*description:[[:space:]]*/, "", val)
      sub(/[[:space:]]+$/, "", val)
      if (val == "" || val ~ /^[|>][0-9]*[+-]?$/) { indesc = 1; next }
      gsub(/^"|"$/, "", val)
      print val
      exit
    }
    indesc {
      if ($0 ~ /^[[:space:]]*$/) next      # skip blank lines within the block
      if ($0 !~ /^[[:space:]]/) exit        # un-indented => next key; description was empty
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$1"
}

# List every skill (and collection) available in the source library, one per
# line as "name  description", and exit. Independent of any project directory.
list_skills() {
  [ -d "$SKILLS_HOME" ] || err "skills home not found at $SKILLS_HOME"

  local -a names=()
  local d n namecol=0
  for d in "$SKILLS_HOME"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    names+=("$n")
    [ "${#n}" -gt "$namecol" ] && namecol="${#n}"
  done

  if [ "${#names[@]}" -eq 0 ]; then
    echo "No skills found in $SKILLS_HOME"
    return 0
  fi

  local cols desccol
  cols="$(tput cols 2>/dev/null || echo 80)"
  [ "$namecol" -gt 30 ] && namecol=30
  desccol=$(( cols - namecol - 4 ))
  [ "$desccol" -lt 20 ] && desccol=20

  echo "Available skills in $SKILLS_HOME:"
  echo
  local dir desc subs count=0
  while IFS= read -r n; do
    dir="$SKILLS_HOME/$n"
    if [ -f "$dir/SKILL.md" ]; then
      desc="$(extract_description "$dir/SKILL.md")"
      [ -n "$desc" ] || desc="(no description)"
    elif is_collection "$dir"; then
      subs="$(find "$dir" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
      desc="[collection] $subs sub-skill(s)"
    else
      desc="(no SKILL.md)"
    fi
    [ "${#desc}" -gt "$desccol" ] && desc="${desc:0:$((desccol - 1))}…"
    printf '  %-*s  %s\n' "$namecol" "$n" "$desc"
    count=$((count + 1))
  done < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
  echo
  echo "$count skill(s). Link one with: $SCRIPT_NAME <name> [--meta]"
}

META=false
LIST=false
SKILLS=()
for arg in "$@"; do
  case "$arg" in
    --meta) META=true ;;
    --list) LIST=true ;;
    --help|-h) usage ;;
    -*) err "unknown flag '$arg'" ;;
    ''|.|..|*/*) err "invalid skill name '$arg'" ;;
    *) SKILLS+=("$arg") ;;
  esac
done

if $LIST; then
  list_skills
  exit 0
fi

[ "${#SKILLS[@]}" -ge 1 ] || usage

command -v python3 >/dev/null 2>&1 || err "python3 is required (used for JSON edits)"

for skill in "${SKILLS[@]}"; do
  if [ -f "$SKILLS_HOME/$skill/SKILL.md" ]; then
    continue
  fi
  if is_collection "$SKILLS_HOME/$skill"; then
    continue
  fi
  echo "error: skill '$skill' not found (expected $SKILLS_HOME/$skill/SKILL.md or a sub-skill collection)" >&2
  echo "available skills:" >&2
  ls -1 "$SKILLS_HOME" >&2
  exit 1
done

PROJECT_ROOT="$(pwd)"
PROJECT_AGENTS_SKILLS="$PROJECT_ROOT/.agents/skills"
PROJECT_CLAUDE_SKILLS="$PROJECT_ROOT/.claude/skills"
PROJECT_CODEX_SKILLS="$PROJECT_ROOT/.codex/skills"
PROJECT_PI_SKILLS="$PROJECT_ROOT/.pi/skills"

mkdir -p "$PROJECT_AGENTS_SKILLS"

# Migrate an old-style real skills directory (e.g. a .claude/skills full of
# per-skill symlinks, from before the folder-symlink layout) into the canonical
# .agents/skills so it can be replaced by a single folder-level symlink.
#
# Safe by construction: a validation pass refuses to touch anything unless every
# entry can be migrated losslessly, entries are then moved or de-duplicated, and
# the directory is removed with rmdir (never rm -rf) so any unexpected leftover
# aborts instead of being deleted.
adopt_real_dir_into_canonical() {
  local dir="$1"
  local entry name canon
  local had_dotglob had_nullglob
  shopt -q dotglob && had_dotglob=1 || had_dotglob=0
  shopt -q nullglob && had_nullglob=1 || had_nullglob=0
  shopt -s dotglob nullglob
  local -a entries=("$dir"/*)
  [ "$had_dotglob" = 1 ] || shopt -u dotglob
  [ "$had_nullglob" = 1 ] || shopt -u nullglob

  # Pass 1: validate. Bail before mutating if any entry would collide with a
  # different existing skill in .agents/skills.
  for entry in "${entries[@]}"; do
    name="$(basename "$entry")"
    [ "$name" = ".DS_Store" ] && continue
    canon="$PROJECT_AGENTS_SKILLS/$name"
    if [ -e "$canon" ] || [ -L "$canon" ]; then
      if ! { [ -L "$entry" ] && [ -L "$canon" ] && [ "$(readlink "$entry")" = "$(readlink "$canon")" ]; }; then
        err "cannot migrate $dir: '$name' also exists in .agents/skills with different content; reconcile the two by hand, then re-run"
      fi
    fi
  done

  # Pass 2: move entries that are new, drop ones that already match.
  local moved=0 dropped=0
  for entry in "${entries[@]}"; do
    name="$(basename "$entry")"
    if [ "$name" = ".DS_Store" ]; then rm -f "$entry"; continue; fi
    canon="$PROJECT_AGENTS_SKILLS/$name"
    if [ ! -e "$canon" ] && [ ! -L "$canon" ]; then
      mv "$entry" "$canon"
      echo "    [adopt]  $name -> .agents/skills/$name"
      moved=$((moved + 1))
    else
      rm -f "$entry"
      dropped=$((dropped + 1))
    fi
  done
  rmdir "$dir" || err "cannot migrate $dir: directory not empty after moving entries; inspect the leftovers manually"
  echo "    (migrated $moved, dropped $dropped duplicate(s))"
}

ensure_folder_symlink() {
  local link="$1"
  local target="$2"
  local parent
  parent="$(dirname "$link")"
  mkdir -p "$parent"
  if [ -L "$link" ]; then
    local current
    current="$(readlink "$link")"
    if [ "$current" = "$target" ]; then
      echo "  [ok]     $link -> $target"
      return
    fi
    err "$link is a symlink to $current (expected $target)"
  fi
  if [ -d "$link" ]; then
    # Older layout: a real skills directory. Adopt its contents into the
    # canonical .agents/skills, then replace it with the folder symlink.
    echo "  [adopt]  $link is a real directory (older layout); migrating into .agents/skills"
    adopt_real_dir_into_canonical "$link"
    ln -s "$target" "$link"
    echo "  [linked] $link -> $target  (migrated from real directory)"
    return
  fi
  if [ -e "$link" ]; then
    err "$link exists and is not a symlink or directory; refusing to clobber"
  fi
  ln -s "$target" "$link"
  echo "  [linked] $link -> $target"
}

echo "Ensuring project skills layout in $PROJECT_ROOT:"
ensure_folder_symlink "$PROJECT_CLAUDE_SKILLS" "../.agents/skills"
ensure_folder_symlink "$PROJECT_CODEX_SKILLS" "../.agents/skills"
ensure_folder_symlink "$PROJECT_PI_SKILLS" "../.agents/skills"

link_skill() {
  local skill="$1"
  local src="$SKILLS_HOME/$skill"
  local dest="$PROJECT_AGENTS_SKILLS/$skill"
  if [ -L "$dest" ]; then
    local current
    current="$(readlink "$dest")"
    if [ "$current" = "$src" ]; then
      echo "  [ok]     $dest -> $src"
      return
    fi
    err "$dest exists and points to $current (expected $src)"
  fi
  if [ -e "$dest" ]; then
    err "$dest exists and is not a symlink; refusing to clobber"
  fi
  ln -s "$src" "$dest"
  echo "  [linked] $dest -> $src"
}

register_meta() {
  local skill="$1"
  local src="$SKILLS_HOME/$skill"
  local skill_md="$src/SKILL.md"
  local registry="$PROJECT_AGENTS_SKILLS/meta-skills.json"

  python3 - "$registry" "$skill" "$src" "$skill_md" <<'PY'
import json, os, sys, datetime
registry_path, name, src, skill_md = sys.argv[1:5]
if os.path.exists(registry_path):
    with open(registry_path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            print(f"error: {registry_path} is not valid JSON ({e}); fix or remove it before re-running", file=sys.stderr)
            sys.exit(1)
else:
    data = {"version": 1, "skills": {}}
if not isinstance(data, dict) or "skills" not in data:
    data = {"version": 1, "skills": {}}
skills = data.setdefault("skills", {})
existing = skills.get(name)
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
if existing:
    if existing.get("path") == skill_md and existing.get("source") == src:
        print(f"  [ok]     meta entry for '{name}' already registered")
        sys.exit(0)
    print(f"error: meta entry for '{name}' already exists with different path ({existing.get('path')}); remove it manually before re-registering", file=sys.stderr)
    sys.exit(1)
skills[name] = {
    "path": skill_md,
    "source": src,
    "registeredAt": now,
}
data["skills"] = {k: skills[k] for k in sorted(skills)}
with open(registry_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"  [meta]   registered '{name}' in {registry_path}")
PY
}

if $META; then
  if [ ! -f "$SKILLS_HOME/$META_SKILL_NAME/SKILL.md" ]; then
    err "meta-skill source missing at $SKILLS_HOME/$META_SKILL_NAME/SKILL.md"
  fi
  if [ ! -L "$PROJECT_AGENTS_SKILLS/$META_SKILL_NAME" ]; then
    echo "Auto-linking the meta-skill itself (required when --meta is used):"
    link_skill "$META_SKILL_NAME"
  fi

  echo "Registering skills in meta-skills.json:"
  for skill in "${SKILLS[@]}"; do
    if [ "$skill" = "$META_SKILL_NAME" ]; then
      echo "  [skip]   '$skill' is the meta-skill itself; auto-linked, not meta-registered"
      continue
    fi
    if [ -L "$PROJECT_AGENTS_SKILLS/$skill" ]; then
      err "'$skill' is already auto-linked at $PROJECT_AGENTS_SKILLS/$skill; cannot also meta-register. Remove the symlink first if you want to convert it."
    fi
    if is_collection "$SKILLS_HOME/$skill"; then
      err "'$skill' is a collection (multiple sub-skills, no top-level SKILL.md); collections can only be auto-linked, not --meta-registered. Re-run without --meta."
    fi
    register_meta "$skill"
  done
else
  echo "Linking skills as auto-trigger:"
  for skill in "${SKILLS[@]}"; do
    link_skill "$skill"
  done
fi

echo "done."
