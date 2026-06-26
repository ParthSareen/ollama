from pathlib import Path

from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext


class OllamaHarnessAgent(BaseAgent):
    """Harbor adapter that runs the Ollama agent harness inside the task env.

    The Ollama CLI runs in Harbor's Docker workspace, while OLLAMA_HOST points
    at the host machine's already-running Ollama daemon.
    """

    SUPPORTS_ATIF = False

    def __init__(
        self,
        logs_dir: Path,
        model_name: str | None = None,
        ollama_host: str = "http://host.docker.internal:11434",
        command_template: str = "ollama run --auto-approve-tools {model}",
        check_host: bool = True,
        go_version: str = "1.26.4",
        run_timeout_sec: int = 900,
        **kwargs,
    ):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)
        self.ollama_host = ollama_host
        self.command_template = command_template
        self.check_host = check_host
        self.go_version = go_version
        self.run_timeout_sec = run_timeout_sec

    @staticmethod
    def name() -> str:
        return "ollama-harness"

    def version(self) -> str:
        return "0.1.0"

    async def setup(self, environment: BaseEnvironment) -> None:
        setup_command = r"""
cat > /tmp/setup-ollama-agent-branch.sh <<'SH'
set -eu

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_prereqs() {
  if need_cmd curl && need_cmd tar && need_cmd gzip && need_cmd python3 && need_cmd bash; then
    return 0
  fi

  if need_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash build-essential ca-certificates curl git gzip python3 tar
  elif need_cmd apk; then
    apk add --no-cache bash build-base ca-certificates curl git gzip python3 tar
  elif need_cmd dnf; then
    dnf install -y bash ca-certificates curl gcc gcc-c++ git gzip make python3 tar
  elif need_cmd yum; then
    yum install -y bash ca-certificates curl gcc gcc-c++ git gzip make python3 tar
  else
    echo "No supported package manager found for installing prerequisites" >&2
    exit 1
  fi

  update-ca-certificates >/dev/null 2>&1 || true
}

install_go() {
  if need_cmd go && go version | grep -q "go1.26"; then
    return 0
  fi

  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) go_arch="amd64" ;;
    aarch64|arm64) go_arch="arm64" ;;
    *) echo "Unsupported Linux architecture for Go: $machine" >&2; exit 1 ;;
  esac

  url="https://go.dev/dl/go${OLLAMA_HARBOR_GO_VERSION}.linux-${go_arch}.tar.gz"
  curl -fsSL "$url" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
}

install_prereqs
install_go

mkdir -p /go/pkg/mod /tmp/go-build-cache /tmp/go-path
chmod 0777 /go /go/pkg /go/pkg/mod /tmp/go-build-cache /tmp/go-path 2>/dev/null || true

cat > /usr/local/bin/ollama-agent-branch <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

cd /ollama-src
export PATH="/usr/local/go/bin:$PATH"
export GOMODCACHE="${GOMODCACHE:-/go/pkg/mod}"
export GOCACHE="${GOCACHE:-/tmp/go-build-cache}"
export GOPATH="${GOPATH:-/tmp/go-path}"
mkdir -p "$GOMODCACHE" "$GOCACHE" "$GOPATH" 2>/dev/null || true

exec go run . run --auto-approve-tools "$@"
WRAPPER
chmod +x /usr/local/bin/ollama-agent-branch

python3 --version
go version
command -v ollama-agent-branch
SH
sh /tmp/setup-ollama-agent-branch.sh
"""
        setup_result = await environment.exec(
            command=setup_command,
            env={
                **self._env(),
                "OLLAMA_HARBOR_GO_VERSION": self.go_version,
            },
            user="root",
            timeout_sec=600,
        )
        self._write_log("setup-install.stdout", setup_result.stdout)
        self._write_log("setup-install.stderr", setup_result.stderr)
        if setup_result.return_code != 0:
            raise RuntimeError(
                "Ollama harness setup failed while installing the branch wrapper."
            )

        checks = [
            "python3 --version",
            "go version",
            "command -v ollama-agent-branch",
        ]
        if self.check_host:
            checks.append('curl -fsS "$OLLAMA_HOST/api/version"')

        result = await environment.exec(
            command=" && ".join(checks),
            env=self._env(),
        )
        self._write_log("setup.stdout", result.stdout)
        self._write_log("setup.stderr", result.stderr)
        if result.return_code != 0:
            raise RuntimeError(
                "Ollama harness setup failed. Confirm the branch source is mounted "
                "at /ollama-src and that the container can reach OLLAMA_HOST."
            )

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        if not self.model_name:
            raise RuntimeError("Harbor model_name is required for OllamaHarnessAgent")

        command = r"""
python3 - <<'PY'
import os
import shlex
import subprocess
import sys

instruction = os.environ["HARBOR_TASK_INSTRUCTION"]
model = os.environ["OLLAMA_MODEL"]
template = os.environ["OLLAMA_HARNESS_COMMAND"]

if "{instruction}" in template:
    rendered = template.format(model=model, instruction=instruction)
    argv = shlex.split(rendered)
else:
    rendered = template.format(model=model)
    argv = shlex.split(rendered)
    argv.append(instruction)

display = " ".join(shlex.quote(part) for part in argv[:-1])
print(f"$ {display} <instruction>", file=sys.stderr)
completed = subprocess.run(argv, cwd="/app", text=True)
raise SystemExit(completed.returncode)
PY
"""
        result = await environment.exec(
            command=command,
            cwd="/app",
            env={
                **self._env(),
                "HARBOR_TASK_INSTRUCTION": instruction,
                "OLLAMA_MODEL": self.model_name,
                "OLLAMA_HARNESS_COMMAND": self.command_template,
            },
            timeout_sec=self.run_timeout_sec,
        )
        self._write_log("run.stdout", result.stdout)
        self._write_log("run.stderr", result.stderr)
        if result.return_code != 0:
            raise RuntimeError(
                "Ollama harness command failed with exit code "
                f"{result.return_code}. See agent/run.stderr in the Harbor job."
            )

    def _env(self) -> dict[str, str]:
        return {
            "OLLAMA_HOST": self.ollama_host,
            "NO_PROXY": "localhost,127.0.0.1,host.docker.internal",
        }

    def _write_log(self, name: str, value: str | None) -> None:
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        (self.logs_dir / name).write_text(value or "")
