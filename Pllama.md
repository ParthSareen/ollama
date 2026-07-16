# Pllama macOS coexistence

Pllama is a long-lived Ollama fork intended to run alongside a normal Ollama
installation on macOS. It preserves the Ollama API and `OLLAMA_*` environment
variables, but uses `127.0.0.1:11433` when `OLLAMA_HOST` is unset. An explicit
`OLLAMA_HOST` continues to take precedence for both the CLI and server.

The packaged app is `Pllama.app` (`com.parthsareen.pllama`) and uses its own
launch agent, application database, PID file, logs, updater cache, and
`/usr/local/bin/pllama` symlink. Its updater is deliberately disabled until a
fork-specific update endpoint exists, so it cannot download an Ollama release
into Pllama.

Model storage is intentionally shared with Ollama at `~/.ollama/models` by
default. This avoids duplicate model downloads; set `OLLAMA_MODELS` or change
the Pllama app's model location to isolate it. Pllama's desktop preferences and
runtime state live under `~/Library/Application Support/Pllama`.

For a local CLI build, run `go build -o pllama .`, then `./pllama serve`. For a
macOS app bundle, run `./scripts/build_darwin.sh`; install the resulting
`dist/Pllama.app` alongside `/Applications/Ollama.app`.

To bring in upstream, fetch `upstream`, merge or rebase `upstream/main`, then
resolve the small Pllama-specific layer in `envconfig`, `app/darwin`,
`app/cmd/app`, `app/server`, `app/store`, `app/updater`, and
`scripts/build_darwin.sh`. Keep the fork-specific behavior in these focused
files rather than renaming upstream packages or module paths.
