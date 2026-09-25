# Dex router: preferred models (Sep 2026)

This sets up an existing Dex router install to use a preferred set of models.
It works with any mix of Anthropic, OpenAI and OpenRouter accounts: one,
several, or none of each. You can add accounts along the way, and existing
accounts are always kept.

It doesn't assume anything about the machine's current config. The script
below works out the target from the machine's accounts, compares it with the
current config, and changes only what differs.

## What it sets up

| Provider | Account rank | In the fallback stack | Native tool route |
|---|---|---|---|
| Anthropic | first | Opus 5.5 → Opus 5 → Fable 5.1 | Claude Code: Opus 5.5 → Opus 5 → Fable 5.1 |
| OpenAI | after Anthropic | GPT-6 Sol → GPT-6 Astra | Codex: GPT-6 Sol → GPT-6 Astra → GPT-5.6 Sol |
| OpenRouter | last | GLM 5.3 → Qwen 3.8 Max → DeepSeek V4 Pro | none |

- The default model and all seven lifecycle phases use one fallback chain:
  the Anthropic models first, then OpenAI, then OpenRouter. A provider with no
  enabled account is left out. With all three providers, the chain runs
  Opus 5.5 → Opus 5 → Fable 5.1 → GPT-6 Sol → GPT-6 Astra → GLM 5.3 →
  Qwen 3.8 Max → DeepSeek V4 Pro.
- Each native tool uses its own provider. Claude Code's `/model` list shows the
  Dex automatic route plus the Anthropic models, and Codex uses the OpenAI
  models. If a tool's provider has no account, its route follows the whole
  stack instead, and Claude Code's list then shows the stack's models.
- OpenRouter bills per token, so it comes last and is only used when the
  subscription accounts can't serve a request.
- Accounts keep their current order within a provider. New accounts go to the
  end of their provider's group. Disabled accounts are kept and ranked but left
  out of routing.
- Effort is `xhigh` everywhere, the context budget is 800000, and native
  routing is on, so plain `claude` and `codex` go through Dex.
- Each Anthropic account must be able to serve the three Anthropic models, and
  each OpenAI account the three Codex models. An account that can't gets a
  fresh login (step 4).

## Before you start

- Dex installed, with the router already set up. If it isn't, run
  `dx setup --router` first.
- zsh. The script is written for zsh, which is the default shell on macOS.
- The Codex CLI, kept up to date, if you use OpenAI accounts. OpenAI's model
  list depends on its version; 0.156.1 is known to include GPT-6 Sol.
- An OpenRouter API key, if you're adding an OpenRouter account.

## Your steps

No command here has inline comments, because zsh treats `#` as an argument by
default.

1. On the machine you're setting up, start Claude Code and send:

   ```
   Read docs/model-upgrade.md in the Dex checkout at $DEX_DIR and carry out its Agent instructions section.
   ```

   The agent lists your existing accounts and asks which accounts you want
   to add. For each, give a provider and a name, or say none. Then it writes
   `~/dex-model-upgrade.sh`, shows you the plan and runs a read-only check.
   It changes nothing itself.

2. Close every Claude Code and Codex session on the machine, including the
   agent's. Use Ctrl-D or `/exit`. Don't use `pkill`, because Claude Code
   respawns and takes the lock again straight away. If the agent reported an
   `opencode serve --service` process, stop it with the pid it gave you:

   ```
   kill <pid>
   ```

3. In a plain terminal:

   ```
   ~/dex-model-upgrade.sh
   ```

   It adds the accounts you asked for first. Anthropic and OpenAI accounts
   open a browser login. OpenRouter asks for the API key, or reads
   `DEX_OPENROUTER_API_KEY` if it's set. Then it applies everything else.

4. If it ends by listing accounts to reauthenticate, run each command it
   prints. Each opens a browser login. Then run the script again, and repeat
   until it ends with `All checks passed.`

5. Start `claude`, run `/model` and pick Claude Opus 5.5. The script
   rebuilds the list but leaves the current selection alone, so pick it once.
   In `codex`, `/model` → GPT-6 Sol, or the Dex automatic route.

6. Restart opencode if you stopped it.

`~/dex-model-upgrade.sh --plan` shows what the target works out to on this
machine, and `--check` compares against it. Both are read-only and safe to run
at any time, including from inside a session.

---

## Agent instructions

You're bringing this machine's existing Dex router (CCR) install to the
preferred-model config above. Its current config could be anything, so
measure it rather than assuming. Don't set up the router from scratch. Don't
copy `~/.dex/router` or any credentials from another machine. Change router
state only through the `dx` CLI.

There's one hard limit. If this session is routed through Dex
(`ANTHROPIC_BASE_URL` contains `/plugins/dex`), catalogue changes (`dx account
add`, `dx account reauth`, `dx model discover`, `dx model add`) are refused
while it's live, and the same goes for any other routed session. `dx router
restart` only reloads the code in place then, so it does not apply a runtime or
catalogue change. So you prepare and verify, and the user applies from a plain
terminal. Don't try to get around the lock.

1. **Inspect** (read-only): `dx router status`, `dx route policy`, `dx accounts`.
   If the router isn't installed or set up, stop and tell the user to run
   `dx setup --router` first.

2. **Ask which accounts to add.** Show the existing accounts (name, provider,
   identity, enabled and status), then ask: *"Which accounts do you want to
   add? Your existing accounts are kept."*
   - For each account, get a provider (`anthropic`, `openai` or `openrouter`)
     and a name. A name is 1–60 letters, numbers, spaces, dots, hyphens or
     underscores, and must not already be in use.
   - "None" is a valid answer.
   - Removing or renaming accounts is out of scope.

3. **Dex version.** The target needs Dex at commit `9df7049` or later
   (github.com/mitchellfyi/dex). Check with
   `git -C "$DEX_DIR" merge-base --is-ancestor 9df7049 HEAD`. If that fails
   and the tree is clean on `main`, run `git -C "$DEX_DIR" pull --ff-only`.
   Otherwise stop and tell the user.

4. **Codex CLI**, only if there is or will be an OpenAI account. Check
   `codex --version`. OpenAI discovery filters the catalogue by this version,
   and 0.156.1 is known to list GPT-6 Sol. If it's older, give the user the
   update command that matches how it's installed (`which codex`).

5. **Native routing** is on in the target. If `dx router native status` shows
   it's off, ask the user before running `dx router native enable`, because it
   changes how plain `claude` and `codex` launch.

6. **Write the script** below to `~/dex-model-upgrade.sh`, verbatim apart from
   `ADD_ACCOUNTS`. Fill that in from step 2 with one quoted
   `"provider name"` entry per account, for example
   `ADD_ACCOUNTS=("anthropic work" "openrouter openrouter")`. Then
   `chmod +x` the script and run `zsh -n` on it.

7. **Show the plan, then check.** Run `~/dex-model-upgrade.sh --plan` and show
   the user the rank order, the stack and the two tool routes it works out to.
   Then run `--check` and report the differences. Every `DIFF` is something
   applying will change. The reauth list is provisional at this stage,
   because applying refreshes every account's model list before it rechecks.

8. **Identify every blocker** the check lists. `claude` sessions close with
   Ctrl-D or `/exit`. An `opencode serve --service` process holds leases
   through the `claude`/`codex` processes it spawns, and needs `kill <pid>`.

9. **Hand over and stop.** Give the user steps 2–6 of "Your steps" with this
   machine's actual pids, and say which new accounts will ask for a login.
   Don't run the script except with `--plan` or `--check`.

Don't:

- `kill` or `pkill` Claude Code or Codex, edit `~/.dex/router/sessions/`, or
  otherwise work around the catalogue lock.
- Hand-edit `~/.dex/router/*.json` or the Dex-managed parts of
  `~/.claude/settings.json` and `~/.codex/config.toml`.
- Put `# comments` in commands the user will paste. zsh has
  `INTERACTIVE_COMMENTS` off by default, so `#` and everything after it become
  arguments.
- Parse router JSON with `sed`, because macOS `sed` has no `\|`. Use `python3`,
  `--plan` or `--check`.

After the user has applied it, run `~/dex-model-upgrade.sh --check`. The
upgrade is done when it exits 0 with `All checks passed.` Any accounts it
still lists for reauth need the user's browser login (step 4).

---

## Updating for new models

When the preferred models change, update this document rather than writing a
new one:

1. Edit the target block at the top of the script: `ANTHROPIC_MODELS`,
   `OPENAI_MODELS`, `CODEX_ROUTE` and `OPENROUTER_MODELS`. OpenRouter entries
   need the upstream ID, context window and image support from OpenRouter's
   model list. Change `EFFORT` or `BUDGET` only if those preferences change.
2. Update the table in "What it sets up", the title's date, and the model
   names in step 5 and in the agent's Codex check (step 4).
3. If the script comes to rely on newer Dex behaviour, raise the minimum
   commit in the agent's step 3.
4. Apply it on one machine, then confirm `--check` passes there before
   relying on it elsewhere.

## The script

This version was tested read-only. `--check` passes on the machine this
config came from. The planning logic was run against made-up account lists:
OpenRouter only; Anthropic only, alongside a disabled OpenAI account; no
accounts; accounts still to add; and names with spaces.

```zsh
#!/bin/zsh
# Dex preferred-model setup (2026-09-23). Per provider, for whichever
# accounts exist:
#   Anthropic   Opus 5.5 -> Opus 5 -> Fable 5.1         (also the Claude Code route)
#   OpenAI      GPT-6 Sol -> GPT-6 Astra                 (Codex route adds GPT-5.6 Sol)
#   OpenRouter  GLM 5.3 -> Qwen 3.8 Max -> DeepSeek V4 Pro
# Accounts rank Anthropic, then OpenAI, then OpenRouter. The fallback stack
# follows the same order and leaves out any provider with no enabled account.
#
#   dex-model-upgrade.sh          apply (needs zero active routed sessions)
#   dex-model-upgrade.sh --plan   what the target works out to on this machine
#   dex-model-upgrade.sh --check  read-only comparison against that target
#
# Existing accounts are always kept. Idempotent: re-run until --check passes.

set -u

# ---- Accounts to add --------------------------------------------------------
# One "provider name" entry each, provider anthropic, openai or openrouter,
# e.g. ("anthropic work" "openrouter openrouter"). Existing names are skipped.
ADD_ACCOUNTS=(
)

# ---- Target per provider ----------------------------------------------------
ANTHROPIC_MODELS=(anthropic/claude-opus-5-5 anthropic/claude-opus-5 anthropic/claude-fable-5-1)
OPENAI_MODELS=(openai/gpt-6-sol openai/gpt-6-astra)
CODEX_ROUTE=(openai/gpt-6-sol openai/gpt-6-astra openai/gpt-5.6-sol)
# id  upstream  default-context  max-context(- for none)  images
OPENROUTER_MODELS=(
  "openrouter/glm-5.3 z-ai/glm-5.3 1048576 1310720 no"
  "openrouter/qwen3.8-max-0902 qwen/qwen3.8-max-0902 1000000 - yes"
  "openrouter/deepseek-v4-pro-0813 deepseek/deepseek-v4-pro-0813 1048576 - no"
)
EFFORT=xhigh
BUDGET=800000

# ---- Setup ------------------------------------------------------------------
if [[ -z "${DEX_DIR:-}" ]]; then
  DEX_DIR=$(grep -m1 '^export DEX_DIR=' ~/.zshrc 2>/dev/null | cut -d= -f2- | tr -d "\"'")
fi
[[ -n "$DEX_DIR" && -f "$DEX_DIR/dx.sh" ]] || { print "DEX_DIR not found; export DEX_DIR and re-run."; exit 1 }
source "$DEX_DIR/dx.sh" || exit 1
ROUTER="$HOME/.dex/router"

step() { print -P "\n%F{cyan}==> $*%f" }
die()  { print -P "\n%F{red}FAILED: $*%f"; exit 1 }

export ANTHROPIC_LIST="${ANTHROPIC_MODELS[*]}" OPENAI_LIST="${OPENAI_MODELS[*]}" CODEX_LIST="${CODEX_ROUTE[*]}"
export OPENROUTER_SPEC="${(F)OPENROUTER_MODELS}" ADD_SPEC="${(F)ADD_ACCOUNTS}" EFFORT BUDGET

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/dexplan.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT

# The target for this machine is derived from its accounts in one place, so
# --plan, --check and apply cannot disagree about it.
cat > "$TMPD/plan.py" <<'PY'
import json, os, re, shlex, sys
mode = sys.argv[1]
policy = json.load(open(sys.argv[2]))
accounts = json.load(open(sys.argv[3]))["accounts"]
settings_path, codex_path = sys.argv[4], sys.argv[5]
E = lambda k: os.environ[k].split()
ORDER = ["anthropic", "openai", "openrouter"]
anthropic_models, openai_models, codex_route = E("ANTHROPIC_LIST"), E("OPENAI_LIST"), E("CODEX_LIST")
openrouter = [line.split() for line in os.environ["OPENROUTER_SPEC"].splitlines() if line.strip()]
effort, budget = os.environ["EFFORT"], int(os.environ["BUDGET"])

adds = []
for line in os.environ.get("ADD_SPEC", "").splitlines():
    if not line.strip(): continue
    provider, _, name = line.strip().partition(" ")
    name = name.strip()
    if provider not in ORDER or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,59}", name):
        sys.exit(f"Bad ADD_ACCOUNTS entry {line!r}: use \"<anthropic|openai|openrouter> <name>\".")
    adds.append((provider, name))

by_name = {a["name"]: a for a in accounts}
pending = {n: p for p, n in adds if n not in by_name}
rank_key = lambda a: (a.get("rank") or 10**9, a.get("created_at") or 0)

# Rank order: provider groups in ORDER, each keeping its current order, with
# accounts still to be added at the end of their group.
ranked, present = [], []
for p in ORDER + sorted({a["provider"] for a in accounts} - set(ORDER)):
    group = [a for a in accounts if a["provider"] == p]
    ranked += [a["name"] for a in sorted(group, key=rank_key)] + [n for n, q in pending.items() if q == p]
    if any(a.get("enabled") for a in group) or p in pending.values():
        present.append(p)

segments = {"anthropic": anthropic_models, "openai": openai_models, "openrouter": [r[0] for r in openrouter]}
stack = [m for p in ORDER if p in present for m in segments[p]]
# A client whose provider has no account follows the full stack, which is what
# it does with no route at all; setting it explicitly also repairs a stale one.
claude = anthropic_models if "anthropic" in present else stack
codex = codex_route if "openai" in present else stack

if mode == "shell":
    arr = lambda k, v: print(f"{k}=({' '.join(shlex.quote(x) for x in v)})")
    arr("PROVIDERS", present); arr("RANKED", ranked); arr("STACK", stack)
    arr("CLAUDE", claude); arr("CODEX", codex); arr("EXISTING", list(by_name))
    arr("DISCOVER", [n for n in ranked if n in by_name and by_name[n].get("enabled") and by_name[n]["provider"] in ("anthropic", "openai")])
    sys.exit(0)

if not stack:
    print("No enabled Anthropic, OpenAI or OpenRouter account, so there is nothing to route.")
    print("Add at least one (ADD_ACCOUNTS, or dx account add) and re-run.")
    sys.exit(1)

if mode == "plan":
    print("Accounts, in rank order:")
    for i, n in enumerate(ranked, 1):
        a = by_name.get(n)
        state = f"{pending[n]}, to add" if not a else a["provider"] + ("" if a.get("enabled") else ", disabled: left out of routing")
        print(f"  {i}. {n}  ({state})")
    print("\nDefault model and phases 0-6:\n  " + " -> ".join(stack))
    print("Claude Code route: " + ("full stack (no Anthropic account)" if "anthropic" not in present else " -> ".join(claude)))
    print("Codex route:       " + ("full stack (no OpenAI account)" if "openai" not in present else " -> ".join(codex)))
    print(f"Effort {effort} everywhere, context budget {budget}, native routing on.")
    sys.exit(0)

diffs, stale = [], []
def report(label, ok, detail=""):
    print(f"  {'ok  ' if ok else 'DIFF'}  {label}{'' if ok else '  -> ' + detail}")
    if not ok: diffs.append(label)
def note(label, detail): print(f"  --    {label}  ({detail})")
route = lambda chain: {"model": chain[0], "fallbacks": chain[1:], "effort": effort}

print("Routes")
report("default model", policy.get("default_model") == stack[0], str(policy.get("default_model")))
for p in map(str, range(7)):
    got = policy.get("phases", {}).get(p)
    report(f"phase {p}", got == route(stack), json.dumps(got))
for client, chain in (("claude", claude), ("codex", codex)):
    got = policy.get("client_routes", {}).get(client)
    report(f"client {client}", got == route(chain), json.dumps(got))
report("context budget", policy.get("context_budget") == budget, str(policy.get("context_budget")))

print("Catalogue")
models = {m["id"]: m for m in policy.get("models", [])}
for mid in dict.fromkeys(stack + claude + codex):
    report(mid, mid in models, "missing")
if "openrouter" in present:
    for mid, upstream, ctx, maxctx, images in openrouter:
        m = models.get(mid)
        if not m: continue
        got = (m.get("upstream_id"), m.get("default_context_window"), m.get("max_context_window"), m.get("capabilities", {}).get("images"))
        exp = (upstream, int(ctx), None if maxctx == "-" else int(maxctx), images == "yes")
        report(f"{mid} metadata", got == exp, f"{got} expected {exp}")

print("Accounts")
for n, p in pending.items():
    report(f"{n} ({p})", False, "not added yet")
for n in ranked:
    a = by_name.get(n)
    if not a: continue
    if not a.get("enabled"): note(n, "disabled, left out of routing"); continue
    report(f"{n} ready", a.get("status") == "ready", f"status={a.get('status')}")
    needed = claude if a["provider"] == "anthropic" else codex if a["provider"] == "openai" else []
    missing = [m for m in needed if a.get("model_ids") is not None and m not in a["model_ids"]]
    if needed:
        report(f"{n} serves its route", not missing, "cannot serve " + ", ".join(missing))
        if missing: stale.append(n)
want = [n for n in ranked if n in by_name]
current = [a["name"] for a in sorted(accounts, key=rank_key)]
report("rank order", current == want and all(by_name[n].get("rank") == i + 1 for i, n in enumerate(want)), " > ".join(current))

print("Native clients")
native = (policy.get("native") or {}).get("enabled") is True
report("native routing enabled", native, "disabled")
if native:
    try:
        picker = json.load(open(settings_path)).get("modelPicker", {}).get("options", [])
        got = [re.sub(r"(\[1m\])+$", "", o.get("model", "")) for o in picker]
        report("Claude picker", got == ["dex/active"] + claude, ", ".join(got))
    except (OSError, ValueError) as e:
        report("Claude picker", False, str(e))
    if "anthropic" not in present:
        note("Claude picker", "no Anthropic account, so it lists the stack's models")
    try:
        report("Codex uses dex-ccr", re.search(r'^model_provider\s*=\s*"dex-ccr"', open(codex_path).read(), re.M) is not None, "model_provider is not dex-ccr")
    except OSError as e:
        report("Codex uses dex-ccr", False, str(e))

if stale:
    print("\nThese accounts cannot serve their route yet. Applying refreshes every account's")
    print("model list first; any still listed after that need a fresh login (browser, zero")
    print("routed sessions), then re-run this script:")
    for n in stale: print(f"  dx account reauth {n}")
    if any(by_name[n]["provider"] == "openai" for n in stale):
        print("  If OpenAI models are still missing afterwards, update the Codex CLI: discovery is filtered by its version.")
print(f"\n{'All checks passed.' if not diffs else f'{len(diffs)} difference(s) from target.'}")
sys.exit(1 if diffs else 0)
PY

snapshot() {
  dx route policy --json > "$TMPD/policy.json" 2>/dev/null || die "dx route policy --json"
  dx accounts --json > "$TMPD/accounts.json" 2>/dev/null || die "dx accounts --json"
}
plan() { python3 "$TMPD/plan.py" "$1" "$TMPD/policy.json" "$TMPD/accounts.json" "$HOME/.claude/settings.json" "$HOME/.codex/config.toml" }
load_plan() { local out; out=$(plan shell) || die "reading the plan"; eval "$out" }

# Mirrors the gateway's own test (service.cjs active()): a session holds the
# catalogue lock while its owner process still has the recorded identity.
routed_sessions() {
  local f pid ident cur
  for f in "$ROUTER"/sessions/*.json(N); do
    grep -q '"active"[[:space:]]*:[[:space:]]*true' "$f" || continue
    pid=$(sed -n 's/.*"owner_pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$f" | head -1)
    ident=$(sed -n 's/.*"owner_identity"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
    [[ -n "$pid" && -n "$ident" ]] || continue
    cur=$(DEX_DIR="$DEX_DIR" bash "$DEX_DIR/bin/router-runtime.sh" identity "$pid" 2>/dev/null | tr -d '\n')
    [[ "$cur" == "$ident" ]] && print -r -- "$(basename "$f" .json)  pid=$pid  $(ps -p "$pid" -o comm= 2>/dev/null)"
  done
}

# ---- Read-only modes --------------------------------------------------------
if [[ "${1:-}" == "--plan" ]]; then
  snapshot; plan plan; exit $?
fi
if [[ "${1:-}" == "--check" ]]; then
  step "Comparing against the target (read-only)"
  snapshot; plan check; code=$?
  blockers=("${(@f)$(routed_sessions)}")
  if [[ -n "${blockers[1]:-}" ]]; then
    print "\nApplying needs these routed sessions closed first:"
    for b in "${blockers[@]}"; do print "  $b"; done
  fi
  exit $code
fi

# ---- Apply ------------------------------------------------------------------
step "Checking for live routed sessions"
blockers=("${(@f)$(routed_sessions)}")
if [[ -n "${blockers[1]:-}" ]]; then
  print -P "%F{red}These routed sessions hold the catalogue lock:%f"
  for b in "${blockers[@]}"; do print "  $b"; done
  print ""
  print "Close each one, then re-run:"
  print "  - Exit Claude Code from inside the session (Ctrl-D or /exit). Do not"
  print "    pkill it: it respawns and re-registers its session immediately."
  print "  - An 'opencode serve --service' daemon holds leases through the"
  print "    claude/codex processes it spawns: kill <pid> shown above."
  die "catalogue changes need zero active routed sessions"
fi
print "None. Proceeding."

snapshot; load_plan

step "Backing up router and client settings"
backup="$HOME/.dex/backups/pre-model-upgrade-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$backup" && cp "$ROUTER/config.json" "$ROUTER/accounts.json" "$backup/" \
  && cp "$HOME/.claude/settings.json" "$HOME/.codex/config.toml" "$backup/" 2>/dev/null
print "  $backup"

step "Restarting the router on the current Dex code"
dx router restart >/dev/null || die "dx router restart"

step "Adding accounts"
added=0
for entry in "${ADD_ACCOUNTS[@]}"; do
  read -r provider name <<< "$entry"
  if (( ${EXISTING[(Ie)$name]} )); then print "  exists  $name"; continue; fi
  print "  adding  $name ($provider)"
  dx account add "$provider" --name "$name" || die "dx account add $provider --name $name"
  added=1
done
(( added )) || print "  none to add"
snapshot; load_plan
(( ${#STACK} )) || { plan plan; die "no enabled account to route to" }

# Every account keeps its own model_ids; routing skips an account for any
# model missing from that list (policy.cjs blockers: model-unavailable).
step "Discovering models for every Anthropic and OpenAI account"
for a in "${DISCOVER[@]}"; do
  if err=$(dx model discover "$a" 2>&1 >/dev/null); then print "  ok      $a"
  else print -P "  %F{yellow}failed  $a: ${err//\%/%%}%f"; fi
done
(( ${#DISCOVER} )) || print "  none"

# Re-adding replaces the entry, so this also corrects drifted metadata.
step "Setting OpenRouter model entries"
if (( ${PROVIDERS[(Ie)openrouter]} )); then
  for line in "${OPENROUTER_MODELS[@]}"; do
    read -r id upstream ctx maxctx images <<< "$line"
    args=(--upstream "$upstream" --context "$ctx" --tools)
    [[ "$maxctx" != "-" ]] && args+=(--max-context "$maxctx")
    [[ "$images" == "yes" ]] && args+=(--images)
    dx model add "$id" "${args[@]}" >/dev/null || die "dx model add $id"
    print "  $id"
  done
else
  print "  skipped: no OpenRouter account"
fi

step "Checking every routed model is in the catalogue"
missing=()
for m in "${STACK[@]}" "${CLAUDE[@]}" "${CODEX[@]}"; do
  dx model list | grep -qE "^${m//./\\.}[[:space:]]" || missing+=("$m")
done
if (( ${#missing} )); then
  print "Missing: ${(u)missing[*]}"
  print "Discovery returned:"; dx model list | grep -E "^(anthropic|openai)/"
  die "stopping before any route change (reauth the accounts above, update Codex CLI for OpenAI models, then re-run)"
fi
print "All present."

step "Ranking accounts: ${RANKED[*]}"
for (( i = 1; i <= ${#RANKED}; i++ )); do
  dx account rank "${RANKED[$i]}" "$i" >/dev/null || die "dx account rank ${RANKED[$i]} $i"
done

step "Setting context budget and routes"
dx context budget "$BUDGET" >/dev/null || die "context budget"
# Sets FB to --fallback <model> for every model after the first.
fallbacks() { FB=(); local m; for m in "${@[2,-1]}"; do FB+=(--fallback "$m"); done }
fallbacks "${STACK[@]}"
dx route configure "${STACK[1]}" "${FB[@]}" --effort "$EFFORT" >/dev/null || die "stack route"
print "  stack: ${STACK[*]}"
if (( ${#CLAUDE} )); then
  fallbacks "${CLAUDE[@]}"
  dx route configure "${CLAUDE[1]}" --client claude "${FB[@]}" --effort "$EFFORT" >/dev/null || die "claude route"
  print "  claude: ${CLAUDE[*]}"
fi
if (( ${#CODEX} )); then
  fallbacks "${CODEX[@]}"
  dx route configure "${CODEX[1]}" --client codex "${FB[@]}" --effort "$EFFORT" >/dev/null || die "codex route"
  print "  codex: ${CODEX[*]}"
fi

step "Verifying"
snapshot; plan check; code=$?
(( code == 0 )) && print "\nStart new claude/codex sessions and pick the model with /model."
exit $code
```
