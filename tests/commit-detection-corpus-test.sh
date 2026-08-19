#!/usr/bin/env bash
set -euo pipefail

# Characterization corpus for git-commit detection in hooks/post-commit-guard.sh.
#
# The PostToolUse hook has to decide whether a Bash command created a commit,
# across the same obfuscation surface the guards cover: wrappers, shells,
# aliases, interpreters, xargs, find -exec, command substitution. The exit
# contract tested elsewhere only exercises plain forms, so this file pins the
# parser's answers for the exotic ones — which is what makes it safe to change
# the parser.
#
# Each case is "<expectation>|<command>", where expectation is commit or none.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-commit-corpus.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
mkdir -p "$HOME"

repo="$TMP_DIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email "dex@example.test"
git -C "$repo" config user.name "Dex Test"

# HEAD carries a deliberately non-conventional message, so the hook's exit
# code reveals the parser's answer: a command it treats as creating a commit
# gets the message validated and is blocked (2); anything else is ignored (0).
printf 'seed\n' > "$repo/seed.txt"
git -C "$repo" add seed.txt
git -C "$repo" commit -q -m "wip not conventional"

pass=0
fail=0

detect() {
  local payload rc
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"exit_code":0}}))' "$1")
  set +e
  printf '%s' "$payload" | (cd "$repo" && bash "$ROOT/hooks/post-commit-guard.sh" >/dev/null 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 2 ]]; then printf 'commit\n'; else printf 'none\n'; fi
}

check() {
  local expected="$1" command="$2" actual
  actual=$(detect "$command")
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL [%s] expected %s, got %s\n' "$command" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}

# Plain forms.
check commit 'git commit -m "feat: x"'
check commit 'git commit --message="feat: x"'
check commit 'git commit -am "feat: x"'
check commit 'git -C . commit -m x'
check commit 'git commit'
check none   'git commit --dry-run -m x'
check none   'git commit --help'
check none   'git commit-tree abc'
check none   'git status'
check none   'git log --oneline'
check none   'echo "git commit -m x"'
check none   'printf "git commit"'

# Wrappers and environment prefixes.
check commit 'command git commit -m x'
check commit 'env GIT_AUTHOR_NAME=x git commit -m y'
check commit 'nice git commit -m x'
check commit 'GIT_AUTHOR_NAME=x git commit -m y'

# Shells.
check commit 'bash -c "git commit -m x"'
check commit 'sh -c "git commit -m x"'
check commit 'zsh -c "git commit -m x"'
check none   'bash -n -c "git commit -m x"'

# Sequencing and grouping.
check commit 'git add -A && git commit -m x'
check commit 'git add -A; git commit -m x'
check commit 'true || git commit -m x'
check commit '{ git commit -m x; }'
check commit '(git commit -m x)'
check none   'git add -A && git status'

# Directory changes. The parser resolves the target directory and only reports
# a commit when it is a git repository, so these are correctly not commits.
check none   'cd /tmp && git commit -m x'
check none   'cd "$HOME" && git commit -m x'

# Interpreters.
check commit 'python3 -c "import subprocess; subprocess.run([\"git\",\"commit\",\"-m\",\"x\"])"'
check commit 'node -e "require(\"child_process\").execSync(\"git commit -m x\")"'
check none   'python3 -c "print(\"git commit\")"'

# xargs and find.
check commit 'echo . | xargs -I{} git commit -m x'
check commit 'find . -name "*.txt" -exec git commit -m x \;'
check none   'find . -name "*.txt" -exec ls {} \;'

# Prefix wrappers: these run the rest as a command, so it must still be read.
check commit 'stdbuf -oL git commit -m x'
check commit 'stdbuf -o L git commit -m x'
check commit 'setsid git commit -m x'
check commit 'unbuffer git commit -m x'
check none   'stdbuf -oL git status'

# Command substitution.
check commit 'git commit -m "$(date)"'
check none   'echo "$(git log -1)"'

# Aliases and functions defined inline.
check commit 'alias gc="git commit"; gc -m x'

# Variables that hold the git command. The bare assignment always worked; the
# three assignment builtins reported "none" until this parser started sharing
# hooks/shell_parse.py with the guard, which had learned them.
check commit 'G=git; $G commit -m x'
check commit 'export G=git; $G commit -m x'
check commit 'declare G=git; $G commit -m x'
check commit 'readonly G=git; $G commit -m x'
check none   'export G=echo; $G commit -m x'
check commit 'find . -name "*.txt" -exec $(echo git) commit -m x \;'
# `${G:-git}` is not a variable named `G:-git`. Reading it as one skipped the
# word before the expansion that resolves it ever ran.
check commit 'G=git; ${G:-git} commit -m x'
check commit '${GIT:-git} commit -m x'
check none   'G=echo; ${G:-git} commit -m x'
# Arithmetic is not a command list, and a substitution inside it is still read.
check none   'echo "total: $(( $(git log --oneline | wc -l) + 1 ))"'

# An xargs item is one argument, not a fresh command line to re-split.
check commit 'printf "a\nb\n" | xargs -I{} git commit -m {}'
check none   'printf "a\nb\n" | xargs -I{} echo git commit -m {}'

# Not a commit even though the word appears.
check none   'grep -r "git commit" .'
check none   'git config alias.ci commit'
check none   'cat commit.txt'

printf 'commit-detection-corpus: %d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0
