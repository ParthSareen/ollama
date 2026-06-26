#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run Ollama agent harness evals through Harbor.

Usage:
  run_harbor_terminal_bench.sh [options] [-- extra harbor args]

Options:
  --mode smoke|tb5|full      Eval mode (default: tb5)
  --model MODEL              Ollama model (default: glm-5.2:cloud)
  --attempts N               Harbor n_attempts (default: 1)
  --concurrency N            Harbor local concurrency (default: 1)
  --repo-root DIR            Ollama repo root (default: inferred)
  --jobs-dir DIR             Harbor jobs dir (default: evals/harbor/jobs/<mode>)
  --dataset-root DIR         Terminal-Bench cache root (default: /tmp/ollama-harbor-terminal-bench)
  --work-dir DIR             Generated config/log dir (default: /tmp/ollama-harbor-run)
  --go-version VERSION       Go version installed in task containers (default: 1.26.4)
  --no-download              Do not download Terminal-Bench; require dataset cache
  --no-serve                 Do not start branch server; use existing OLLAMA_HOST
  --keep-server              Do not stop branch server on exit
  --install-harbor           Install Harbor with uv if harbor is missing
  --dry-run                  Generate config and print commands without running
  -h, --help                 Show this help

Examples:
  skills/harbor-terminal-bench-eval/scripts/run_harbor_terminal_bench.sh --mode tb5
  skills/harbor-terminal-bench-eval/scripts/run_harbor_terminal_bench.sh --mode full --model glm-5.2:cloud
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_repo_root="$(cd "$script_dir/../../.." && pwd)"

mode="tb5"
model="glm-5.2:cloud"
attempts="1"
concurrency="1"
repo_root="$default_repo_root"
jobs_dir=""
dataset_root="/tmp/ollama-harbor-terminal-bench"
work_dir="/tmp/ollama-harbor-run"
go_version="1.26.4"
download_dataset="1"
start_server="1"
keep_server="0"
install_harbor="0"
dry_run="0"
extra_harbor_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --attempts) attempts="$2"; shift 2 ;;
    --concurrency) concurrency="$2"; shift 2 ;;
    --repo-root) repo_root="$(cd "$2" && pwd)"; shift 2 ;;
    --jobs-dir) jobs_dir="$2"; shift 2 ;;
    --dataset-root) dataset_root="$2"; shift 2 ;;
    --work-dir) work_dir="$2"; shift 2 ;;
    --go-version) go_version="$2"; shift 2 ;;
    --no-download) download_dataset="0"; shift ;;
    --no-serve) start_server="0"; shift ;;
    --keep-server) keep_server="1"; shift ;;
    --install-harbor) install_harbor="1"; shift ;;
    --dry-run) dry_run="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; extra_harbor_args=("$@"); break ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$mode" in
  smoke|tb5|full) ;;
  *) echo "--mode must be smoke, tb5, or full" >&2; exit 2 ;;
esac

if [[ -z "$jobs_dir" ]]; then
  jobs_dir="evals/harbor/jobs/$mode"
fi

adapter_path="$repo_root/evals/harbor/agents/ollama_harness_agent.py"
if [[ ! -f "$adapter_path" ]]; then
  echo "missing Harbor adapter: $adapter_path" >&2
  exit 1
fi

if [[ "$dry_run" != "1" ]] && ! command -v harbor >/dev/null 2>&1; then
  if [[ "$install_harbor" == "1" ]] && command -v uv >/dev/null 2>&1; then
    uv tool install harbor
  else
    echo "harbor is not on PATH. Install it first or pass --install-harbor." >&2
    exit 1
  fi
fi

if [[ "$dry_run" != "1" && "$start_server" == "1" ]]; then
  if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    echo "127.0.0.1:11434 is already serving. Stop it first or pass --no-serve." >&2
    exit 1
  fi
fi

mkdir -p "$work_dir" "$dataset_root" \
  /tmp/ollama-harbor-go-mod /tmp/ollama-harbor-go-build /tmp/ollama-harbor-go-path

dataset_path=""
task_names=()
if [[ "$mode" == "smoke" ]]; then
  dataset_path="$repo_root/evals/harbor/tasks"
elif [[ "$mode" == "tb5" || "$mode" == "full" ]]; then
  dataset_path="$dataset_root/terminal-bench-2-1"
  if [[ "$dry_run" != "1" && ! -d "$dataset_path" ]]; then
    if [[ "$download_dataset" != "1" ]]; then
      echo "missing Terminal-Bench dataset at $dataset_path" >&2
      exit 1
    fi
    harbor dataset download terminal-bench/terminal-bench-2-1 \
      -o "$dataset_root" --export --overwrite
  fi
  if [[ "$mode" == "tb5" ]]; then
    task_names=(
      "fix-git"
      "regex-log"
      "sqlite-db-truncate"
      "cancel-async-tasks"
      "nginx-request-logging"
    )
  fi
fi

compose_overlay="$work_dir/host-gateway-compose.yaml"
cat > "$compose_overlay" <<'YAML'
services:
  main:
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML

config_path="$work_dir/harbor-${mode}.json"
TASK_NAMES_JOINED="$(IFS=,; echo "${task_names[*]-}")"
export HARBOR_MODE="$mode"
export HARBOR_MODEL="$model"
export HARBOR_ATTEMPTS="$attempts"
export HARBOR_CONCURRENCY="$concurrency"
export HARBOR_REPO_ROOT="$repo_root"
export HARBOR_JOBS_DIR="$jobs_dir"
export HARBOR_DATASET_PATH="$dataset_path"
export HARBOR_TASK_NAMES="$TASK_NAMES_JOINED"
export HARBOR_COMPOSE_OVERLAY="$compose_overlay"
export HARBOR_CONFIG_PATH="$config_path"
export HARBOR_GO_VERSION="$go_version"

python3 - <<'PY'
import json
import os
from pathlib import Path

tasks = [t for t in os.environ["HARBOR_TASK_NAMES"].split(",") if t]
dataset = {"path": os.environ["HARBOR_DATASET_PATH"]}
if tasks:
    dataset["task_names"] = tasks

config = {
    "jobs_dir": os.environ["HARBOR_JOBS_DIR"],
    "n_attempts": int(os.environ["HARBOR_ATTEMPTS"]),
    "timeout_multiplier": 1.0,
    "orchestrator": {
        "type": "local",
        "n_concurrent_trials": int(os.environ["HARBOR_CONCURRENCY"]),
    },
    "environment": {
        "type": "docker",
        "force_build": False,
        "delete": True,
        "mounts": [
            {
                "type": "bind",
                "source": os.environ["HARBOR_REPO_ROOT"],
                "target": "/ollama-src",
                "read_only": True,
                "bind": {"create_host_path": False},
            },
            {"type": "bind", "source": "/tmp/ollama-harbor-go-mod", "target": "/go/pkg/mod"},
            {"type": "bind", "source": "/tmp/ollama-harbor-go-build", "target": "/tmp/go-build-cache"},
            {"type": "bind", "source": "/tmp/ollama-harbor-go-path", "target": "/tmp/go-path"},
        ],
        "extra_docker_compose": [os.environ["HARBOR_COMPOSE_OVERLAY"]],
    },
    "agents": [
        {
            "import_path": "evals.harbor.agents.ollama_harness_agent:OllamaHarnessAgent",
            "model_name": os.environ["HARBOR_MODEL"],
            "kwargs": {
                "ollama_host": "http://host.docker.internal:11434",
                "command_template": "ollama-agent-branch {model}",
                "check_host": True,
                "go_version": os.environ["HARBOR_GO_VERSION"],
                "run_timeout_sec": 900,
            },
        }
    ],
    "datasets": [dataset],
}

path = Path(os.environ["HARBOR_CONFIG_PATH"])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(config, indent=2) + "\n")
print(path)
PY

echo "mode=$mode model=$model attempts=$attempts concurrency=$concurrency"
echo "config=$config_path"
echo "jobs_dir=$jobs_dir"

if [[ "$dry_run" == "1" ]]; then
  echo "dry run: not starting server or running Harbor"
  echo "would run: (cd '$repo_root' && PYTHONPATH='$repo_root' harbor run -c '$config_path' ${extra_harbor_args[*]-})"
  exit 0
fi

server_pid=""
if [[ "$start_server" == "1" ]]; then
  serve_log="$work_dir/ollama-serve.log"
  (cd "$repo_root" && go run . serve >"$serve_log" 2>&1) &
  server_pid="$!"
  echo "started branch server pid=$server_pid log=$serve_log"
  for _ in $(seq 1 120); do
    if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    echo "branch server did not become ready; see $serve_log" >&2
    exit 1
  fi
fi

cleanup() {
  if [[ -n "$server_pid" && "$keep_server" != "1" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

(cd "$repo_root" && PYTHONPATH="$repo_root" harbor run -c "$config_path" "${extra_harbor_args[@]}")
