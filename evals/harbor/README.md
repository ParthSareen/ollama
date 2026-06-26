# Harbor Ollama Harness Eval

This is a minimal Harbor setup for evaluating the Ollama agent harness in a
real Harbor Docker task while using the local Ollama daemon for inference.

## Prerequisites

- Docker is running.
- Harbor is installed, for example `uv tool install harbor`.
- Ollama is serving on the host: `ollama serve`.
- The configured model is already pulled locally.

The sample task image installs Go and runs the branch CLI from this worktree
through a read-only bind mount at `/ollama-src`. That CLI talks to your host
daemon through:

```sh
OLLAMA_HOST=http://host.docker.internal:11434
```

## Run

From the repository root:

```sh
PYTHONPATH="$PWD" harbor run -c evals/harbor/ollama-harness-smoke.yaml
```

To use a different local model, edit `model_name` in
`evals/harbor/ollama-harness-smoke.yaml`.

If your CLI command differs, edit `command_template`. The adapter appends the
Harbor instruction as the final argument unless the template contains an
`{instruction}` placeholder.

The default command template runs the branch CLI inside the Harbor task
container:

```sh
ollama-agent-branch {model}
```

## What This Tests

The smoke task asks the agent to create `/app/hello.txt`. Harbor then runs
`tests/test.sh` inside the same Docker workspace and writes reward `1` only
when the file contains exactly `Hello, world!`.

This validates the important Harbor contract: the agent runs in the same
filesystem the verifier grades.

## Important Caveat

This evaluates the agent harness from the mounted branch source. It uses
`go run`, so the first run may spend extra time compiling and downloading Go
modules inside the Harbor container.
