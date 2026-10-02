"""Harbor agent that runs Dex's benchmark workflow inside a task container.

Harbor (https://github.com/harbor-framework/harbor) is the harness behind
Terminal-Bench 2 and ships SWE-bench-family datasets. Its built-in
``claude-code`` agent is the baseline; this agent runs the same Claude Code
under Dex so the two can be compared on the same model and tasks.

Dex runs as ``dx run --spec`` with ``workflow.name: benchmark``: Plan,
Implement and Review in one headless Claude session, with no ticket, remote,
PR or reviewer (see docs/benchmarks.md). Harbor's verifier then scores the
working tree Dex leaves behind.

Usage, from the Dex checkout::

    PYTHONPATH=research/public-benchmarks harbor run -d terminal-bench-sample@2.0 \
        -a dex_agent:DexAgent -m anthropic/claude-sonnet-5-5 -n 1 -l 1

``research/public-benchmarks/run.sh`` wraps this and the matching baseline run.

Agent kwargs (``--ak key=value``):
  dex_dir           Dex checkout to upload (default: this file's checkout)
  reasoning_effort  low|medium|high|xhigh|max, passed as the run's effort
  phase_timeout     Seconds one lifecycle phase may run before Dex stops it
                    (default 1200). A stalled session then fails fast instead
                    of spending the whole task budget.
  phases            Benchmark phases to run, comma-separated (default
                    plan,implement,review). Leave out plan or review to
                    measure what each contributes.
  review_tier       Force the review depth: trivial, small, normal, complex.
                    Unset lets Implement choose, as a normal lifecycle does.

Harbor imports this module inside its own tool environment, so it may only
use the standard library and Harbor's own packages.
"""

from __future__ import annotations

import json
import secrets
import shlex
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

from harbor.agents.installed.base import PackageSpec
from harbor.agents.installed.claude_code import ClaudeCode
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

# Where Dex lives inside the container.
REMOTE_DEX_DIR = "/opt/dex"
# What `dx run` needs at run time. docs/, tests/ and research/ stay behind.
RUNTIME_PATHS = (
    "dx.sh",
    "settings.json",
    "bin",
    "hooks",
    "lib",
    "prompts",
    "scripts",
    "skills",
    "templates",
)
# The local base branch the lifecycle branches from and reviews against.
BASE_BRANCH = "dex-bench-base"

# Runs in the task's working directory before Dex starts. Dex needs a git
# checkout with a local default branch; a Terminal-Bench /app is often not a
# repository at all. Only git metadata changes: the files on disk are the ones
# the task shipped.
PREPARE_SCRIPT = r"""
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

mkdir -p "$CLAUDE_CONFIG_DIR" "$DEX_BENCH_DIR"
ln -sfn "$DEX_DIR/skills" "$CLAUDE_CONFIG_DIR/skills"

# Dex strips ANTHROPIC_* from the environment it launches Claude with, so
# provider isolation holds on a developer machine. In here the key reaches
# Claude as an apiKeyHelper, and a custom base URL or the workspace header
# through settings env. The key file stays out of /logs, which Harbor copies
# back to the host.
(
  umask 077
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    printf '%s' "$ANTHROPIC_API_KEY" > "$DEX_BENCH_DIR/api-key"
  fi
)
python3 - <<'PY'
import json
import os

home = os.path.expanduser("~")
source = os.path.join(home, ".claude", "settings.json")
target = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "settings.json")
settings = {}
if os.path.exists(source):
    with open(source, encoding="utf-8") as handle:
        settings = json.load(handle)
if os.environ.get("ANTHROPIC_API_KEY"):
    key_file = os.path.join(os.environ["DEX_BENCH_DIR"], "api-key")
    settings["apiKeyHelper"] = f"cat {key_file}"
for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS"):
    if os.environ.get(name):
        settings.setdefault("env", {})[name] = os.environ[name]
with open(target, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2)
PY

git config --global user.email >/dev/null 2>&1 || git config --global user.email "dex-bench@localhost"
git config --global user.name >/dev/null 2>&1 || git config --global user.name "Dex Benchmark"
git config --global --add safe.directory '*'

repo=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo" ]; then
  repo=$PWD
  git -C "$repo" init -q
fi
cd "$repo"
exclude=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$exclude")"
grep -qxF '.dex/' "$exclude" 2>/dev/null || printf '.dex/\n' >> "$exclude"
git switch -q -c "$DEX_BENCH_BASE" 2>/dev/null || git switch -q "$DEX_BENCH_BASE"
if ! git rev-parse -q --verify HEAD >/dev/null || [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -q --allow-empty --no-verify -m "dex-bench: starting tree"
fi
printf '%s\n' "$repo" > "$DEX_BENCH_DIR/repo"
"""

# Starts the lifecycle and keeps what a later reader needs. A Dex failure is
# recorded rather than raised: the verifier still scores whatever is on disk,
# exactly as it would for a baseline agent that crashed.
RUN_SCRIPT = r"""
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(cat "$DEX_BENCH_DIR/repo")"
zsh -fc 'source "$DEX_DIR/dx.sh" && dx run --spec "$DEX_BENCH_DIR/spec.json"' \
  2>&1 | tee /logs/agent/dex.txt
status=${PIPESTATUS[0]}
printf '%s\n' "$status" > /logs/agent/dex-exit-code
mkdir -p /logs/agent/dex-state
cp -R "$HOME/.dex/runs" /logs/agent/dex-state/runs 2>/dev/null || true
cp -R "$HOME/.claude/.dex-phases" /logs/agent/dex-state/phases 2>/dev/null || true
git status --short > /logs/agent/dex-git-status.txt 2>&1 || true
git log --oneline "$DEX_BENCH_BASE..HEAD" > /logs/agent/dex-git-log.txt 2>&1 || true
exit 0
"""


class DexAgent(ClaudeCode):
    """Claude Code driven by Dex's benchmark lifecycle."""

    SYSTEM_PACKAGES = {**ClaudeCode.SYSTEM_PACKAGES, "zsh": PackageSpec.standard("zsh")}

    @staticmethod
    def name() -> str:
        return "dex"

    def __init__(
        self,
        logs_dir: Path,
        *args: Any,
        dex_dir: str | None = None,
        phase_timeout: int = 1200,
        phases: str = "plan,implement,review",
        review_tier: str | None = None,
        **kwargs: Any,
    ):
        self._phase_timeout = int(phase_timeout)
        self._phases = [p.strip() for p in str(phases).split(",") if p.strip()]
        if review_tier not in (None, "trivial", "small", "normal", "complex"):
            raise ValueError(f"review_tier must be trivial, small, normal or complex: {review_tier}")
        self._review_tier = review_tier
        default_dir = Path(__file__).resolve().parents[2]
        self._dex_dir = Path(dex_dir).expanduser().resolve() if dex_dir else default_dir
        if not (self._dex_dir / "dx.sh").is_file():
            raise ValueError(f"dex_dir does not look like a Dex checkout: {self._dex_dir}")
        super().__init__(logs_dir, *args, **kwargs)

    def _dex_revision(self) -> str:
        result = subprocess.run(
            ["git", "-C", str(self._dex_dir), "describe", "--always", "--dirty"],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.stdout.strip() or "unknown"

    def _stage_dex(self) -> Path:
        """Copy the runtime part of the checkout, uncommitted edits included."""
        listed = subprocess.run(
            ["git", "-C", str(self._dex_dir), "ls-files", "-z", "--cached",
             "--others", "--exclude-standard", "--", *RUNTIME_PATHS],
            capture_output=True,
            check=True,
        ).stdout
        stage = Path(tempfile.mkdtemp(prefix="dex-harbor-stage-"))
        for raw in listed.split(b"\0"):
            if not raw:
                continue
            relative = raw.decode()
            source = self._dex_dir / relative
            if not source.is_file():
                continue  # deleted in the working tree
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        (stage / "REVISION").write_text(self._dex_revision() + "\n", encoding="utf-8")
        return stage

    async def install(self, environment: BaseEnvironment) -> None:
        await super().install(environment)
        await self.ensure_system_dependencies(environment, ("zsh", "git", "python3"))
        stage = self._stage_dex()
        try:
            await self.exec_as_root(
                environment, command=f"rm -rf {REMOTE_DEX_DIR} && mkdir -p {REMOTE_DEX_DIR}"
            )
            await environment.upload_dir(stage, REMOTE_DEX_DIR)
        finally:
            shutil.rmtree(stage, ignore_errors=True)
        await self.exec_as_root(
            environment,
            command=(
                f"chmod -R a+rX {REMOTE_DEX_DIR} && "
                f"chmod +x {REMOTE_DEX_DIR}/hooks/*.sh {REMOTE_DEX_DIR}/bin/*.sh"
            ),
        )
        await self.exec_as_agent(
            environment,
            command=(
                "mkdir -p ~/.claude && "
                f"ln -sfn {REMOTE_DEX_DIR}/skills ~/.claude/skills && "
                f"DEX_DIR={REMOTE_DEX_DIR} bash {REMOTE_DEX_DIR}/bin/install-settings.sh --quiet"
            ),
        )

    def _run_spec(self, instruction: str, repo: str) -> dict[str, Any]:
        harness: dict[str, Any] = {"name": "claude-code"}
        model = self._resolved_model_name()
        if model:
            harness["model"] = model
        if self.options.reasoning_effort:
            harness["effort"] = self.options.reasoning_effort
        return {
            "run_id": f"run_bench-{int(time.time())}-{secrets.token_hex(4)}",
            "repository": {
                "provider": "local",
                "default_branch": BASE_BRANCH,
                "working_directory": repo,
            },
            "source": {"type": "task", "title": "Benchmark task", "body": instruction},
            "harness": harness,
            "workflow": {"name": "benchmark", "version": "v1", "phases": self._phases},
        }

    async def run(
        self, instruction: str, environment: BaseEnvironment, context: AgentContext
    ) -> None:
        sessions_dir = (self.environment_logs_dir / "sessions").as_posix()
        env = self._resolve_auth_env()
        env.update(
            {
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                # Claude refuses --dangerously-skip-permissions as root otherwise.
                "IS_SANDBOX": "1",
                "CLAUDE_CONFIG_DIR": sessions_dir,
                "DEX_DIR": REMOTE_DEX_DIR,
                "DEX_BENCH_DIR": "/tmp/dex-bench",
                "DEX_BENCH_BASE": BASE_BRANCH,
                "DEXCODE_SYNC": "0",
                "DX_RTK_ENABLED": "0",
                # Hook start and finish times, API retries: what a stalled
                # session needs to explain itself afterwards.
                "DX_CLAUDE_DEBUG_FILE": "/logs/agent/claude-debug.log",
                "DEX_PHASE_TIMEOUT": str(self._phase_timeout),
            }
        )
        if self._review_tier:
            env["DEX_REVIEW_TIER"] = self._review_tier
        env.update(self._resolved_env_vars)

        await self.exec_as_agent(environment, command=PREPARE_SCRIPT, env=env)
        repo_result = await environment.exec(command="cat /tmp/dex-bench/repo", env=env)
        repo = (repo_result.stdout or "").strip()
        if not repo:
            raise RuntimeError("Dex benchmark preparation did not record a repository")

        spec = json.dumps(self._run_spec(instruction, repo))
        await self.exec_as_agent(
            environment,
            command=(
                "umask 077 && printf '%s' \"$DEX_BENCH_SPEC\" > /tmp/dex-bench/spec.json && "
                f"printf 'dex %s\\n' {shlex.quote(self._dex_revision())} > /logs/agent/dex-version"
            ),
            env={**env, "DEX_BENCH_SPEC": spec},
        )
        await self.exec_as_agent(environment, command=RUN_SCRIPT, env=env)

    def populate_context_post_run(self, context: AgentContext) -> None:
        """Count every Claude session Dex started, not only the lifecycle.

        Review waves are separate Claude processes. They share the config
        directory, but one that runs from another working directory lands in
        another project folder, and the base class gives up when it finds more
        than one. Write the trajectory for the largest session folder and
        report usage summed across all of them.
        """
        session_dirs = self._session_dirs(self.logs_dir)
        totals = {"cost": 0.0, "prompt": 0, "cached": 0, "completion": 0}
        primary = None
        primary_steps = -1
        for session_dir in session_dirs:
            try:
                trajectory = self._convert_events_to_trajectory(session_dir)
            except Exception as exc:  # a malformed session must not hide the others
                self.logger.debug(f"Could not read Dex session {session_dir}: {exc}")
                continue
            if not trajectory:
                continue
            metrics = trajectory.final_metrics
            if metrics:
                totals["cost"] += metrics.total_cost_usd or 0.0
                totals["prompt"] += metrics.total_prompt_tokens or 0
                totals["cached"] += metrics.total_cached_tokens or 0
                totals["completion"] += metrics.total_completion_tokens or 0
            if len(trajectory.steps) > primary_steps:
                primary, primary_steps = trajectory, len(trajectory.steps)

        if primary is not None:
            with open(self.logs_dir / "trajectory.json", "w", encoding="utf-8") as handle:
                json.dump(primary.to_json_dict(), handle, indent=2, ensure_ascii=False)
        if session_dirs:
            context.cost_usd = totals["cost"]
            context.n_input_tokens = totals["prompt"]
            context.n_cache_tokens = totals["cached"]
            context.n_output_tokens = totals["completion"]
