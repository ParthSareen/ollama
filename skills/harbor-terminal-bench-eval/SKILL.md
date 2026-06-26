---
name: harbor-terminal-bench-eval
description: Run Ollama agent harness evaluations through Harbor, including the local smoke task, a 5-task Terminal-Bench probe, or the full Terminal-Bench 2.1 dataset. Use when Codex needs to prepare, launch, monitor, stop, or summarize long-running Harbor/Terminal-Bench evals for an Ollama agent branch using a local Ollama server and Docker task sandboxes.
---

# Harbor Terminal-Bench Eval

## Use This Workflow

Use the bundled runner script unless the user asks for manual commands:

```sh
skills/harbor-terminal-bench-eval/scripts/run_harbor_terminal_bench.sh --mode tb5
```

Modes:

- `smoke`: run the repo-local Harbor hello-file smoke task.
- `tb5`: download Terminal-Bench 2.1 if needed and run 5 selected tasks.
- `full`: download Terminal-Bench 2.1 if needed and run all 89 tasks.

The script starts `go run . serve` from the current branch, waits for
`/api/version`, generates a Harbor config with this machine's absolute repo
path, runs Harbor, and stops the server on exit.

## Before Running

Check these prerequisites:

- Docker is running.
- `go` is available in the host shell and satisfies the repo `go.mod`.
- `harbor` is installed, or `uv` is installed so the script can install Harbor.
- The model is available/authenticated for the local Ollama daemon, default
  `glm-5.2:cloud`.
- The repo contains `evals/harbor/agents/ollama_harness_agent.py`; Harbor imports
  this adapter via `PYTHONPATH=<repo root>`.

If another Ollama server is already on `127.0.0.1:11434`, stop it first or pass
`--no-serve` only when intentionally using that existing server.

## Common Commands

Run a quick smoke:

```sh
skills/harbor-terminal-bench-eval/scripts/run_harbor_terminal_bench.sh --mode smoke
```

Run the 5-task probe:

```sh
skills/harbor-terminal-bench-eval/scripts/run_harbor_terminal_bench.sh --mode tb5
```

Run full Terminal-Bench 2.1:

```sh
skills/harbor-terminal-bench-eval/scripts/run_harbor_terminal_bench.sh --mode full
```

Run full benchmark and leave it running in `tmux`:

```sh
tmux new -s harbor-tbench
skills/harbor-terminal-bench-eval/scripts/run_harbor_terminal_bench.sh --mode full
```

Useful options:

- `--model MODEL`: set the Ollama model, for example `glm-5.2:cloud`.
- `--attempts N`: set Harbor `n_attempts`.
- `--concurrency N`: set Harbor local trial concurrency. Keep `1` for local
  Ollama unless deliberately testing parallelism.
- `--jobs-dir DIR`: choose where Harbor writes results.
- `--dataset-root DIR`: choose where Terminal-Bench task definitions are cached.
- `--keep-server`: leave the branch server running after Harbor exits.
- `--no-serve`: do not start `go run . serve`; use an already-running daemon.
- `--`: pass remaining args through to `harbor run`.

## Expected Size And Runtime

Terminal-Bench 2.1 has 89 tasks. With `--attempts 1`, full mode runs 89 trials.
With `--attempts 5`, it runs 445 trials.

The current adapter preserves Harbor's per-task Docker isolation. It mounts the
branch source into each task container and installs/runs a small
`ollama-agent-branch` wrapper there. Cold task images and Go setup make this
slow. A prior 5-task serial probe took about 18m46s before interruption and
recorded 3 passes, 1 error, 1 cancel. Treat full mode as an hours-long run.

## Monitoring And Stopping

Harbor writes under the configured `jobs_dir`, with timestamped job folders.
Inspect while running:

```sh
find evals/harbor/jobs -name result.json | sort | tail
```

View completed results:

```sh
harbor view <jobs-dir>
```

Stop a foreground run with `Ctrl-C`. The script traps exit and stops its branch
server unless `--keep-server` was passed. If manually launched processes remain,
look for `harbor run`, `go run . serve`, `ollama-agent-branch`, and Docker
compose processes and stop only those eval-related processes.

## Implementation Notes

The Harbor adapter lives at `evals/harbor/agents/ollama_harness_agent.py`.
It installs a wrapper inside each task container that executes:

```sh
go run . run --auto-approve-tools "$@"
```

from `/ollama-src`, a read-only bind mount of the repo branch. The model server
stays on the host and containers reach it at:

```sh
http://host.docker.internal:11434
```

The runner adds a Docker Compose `extra_hosts` overlay for Linux Docker so
`host.docker.internal` maps to `host-gateway`.
