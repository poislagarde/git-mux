# git-mux

Run a git command across many repositories **serially**, with **per-host SSH connection
multiplexing** — so a bulk operation like `git mux pull` doesn't trip a server's connection-rate
throttle the way many parallel pulls do.

It's a small, dependency-free bash script that installs as a git subcommand (`git mux …`).

## The problem it solves

Running a multi-repo update that fires many SSH connections at once (e.g. dozens of `git pull`s in
parallel) can trip a host's **SSH connection-rate throttle**. On GitHub the symptom is:

```
kex_exchange_identification: Connection timed out during banner exchange
Connection to github.com port 22 timed out
fatal: Could not read from remote repository.
```

Unlike the REST API, SSH gives you **no `Retry-After` header** to read — the connection dies during
the handshake. So `git-mux` attacks the root cause instead of guessing wait times:

- **One shared SSH connection per host.** All operations to the same server reuse a single
  persistent connection (OpenSSH `ControlMaster`), so the server's per-IP connection counter barely
  moves. This works for any SSH git host — GitHub, GitLab, Bitbucket, self-hosted.
- **Serial execution.** One repo at a time, so connections don't burst.
- **Retry with backoff** on transient/throttle errors, with feedback printed to stderr (so you can
  see it's waiting, not hung — even under `-q`).

https and local remotes work too; multiplexing simply doesn't apply to them.

## Install

```bash
git clone git@github.com:poislagarde/git-mux.git
cd git-mux
./install.sh
```

`install.sh` symlinks the script into a bin directory (`$HOME/.local/bin` by default; override with
the `GIT_MUX_BIN` env var). It's idempotent — re-run it after a `git pull`. Make sure that directory
is on your `PATH`. Naming the script `git-mux` is what makes it available as `git mux`.

No installer needed, really — it's one self-contained script. Symlinking or copying `git-mux` (keeping
that name) into any directory on your `PATH` is equivalent.

## Shell completion (zsh)

git-mux ships a zsh completion at [`completions/_git-mux`](completions/_git-mux). It completes
git-mux's own flags and then delegates to git's command completion — so `git mux sw<TAB>` expands to
`git mux switch`, just like a plain `git switch`.

It is **not** auto-installed: zsh discovers completions via `$fpath`, and there's no XDG-standard
completion directory that's on `fpath` by default — so where it belongs depends on your setup. Enable
it whichever way fits yours:

- **Point `fpath` at this repo** (auto-updates on `git pull`). In `~/.zshrc`, *before* `compinit`:
  ```sh
  fpath=(/path/to/git-mux/completions $fpath)
  autoload -Uz compinit && compinit
  ```
- **Or drop the file into a directory already on your `fpath`** — symlink or copy
  `completions/_git-mux` there (run `print -l $fpath` to see your directories), then start a fresh
  shell (`rm -f "$HOME"/.zcompdump*` if it doesn't show up).

## Usage

```bash
git mux pull                      # `git pull` in every repo under the cwd
git mux pull --rebase --autostash
git mux fetch --all --prune
git mux status -sb
git mux -d 2 pull                  # search two directory levels deep
git mux -n pull                    # dry run: list repos + plan, run nothing
```

By default each repo's output is printed under a clear `━━━ [i/total] name ━━━` header, so you can
tell which output belongs to which repo; pass `-q` for a one-line status per repo instead.

Repo discovery mirrors [`git multi`](https://github.com/tkrajina/git-plus): immediate
subdirectories of the current directory by default, `-d N` to recurse deeper.

### Options

| Option | Description |
| --- | --- |
| `-d, --depth N` | directory levels to search for repos (default `1`) |
| `-C, --dir DIR` | base directory to scan (default: current directory) |
| `-r, --retries N` | retries per repo on transient network/throttle errors (default `3`) |
| `-b, --backoff "S..."` | space-separated backoff seconds per retry (default `"5 15 45"`) |
| `--no-mux` | disable SSH connection multiplexing |
| `-q, --quiet` | one concise status line per repo instead of full output (failures still show output; retries go to stderr) |
| `-n, --dry-run` | show discovered repos, hosts and plan, then exit |
| `-h, --help` | show help |

The exit status is the number of repos that failed, capped at `255` (`0` = all succeeded), so it composes in scripts.

> Note: `git mux --help` won't work — git intercepts `--help` to look for a man page. Run
> `git-mux --help` directly, or `git mux -n <cmd>` for a dry run.

## How it works

For the run, `git-mux` exports a `GIT_SSH_COMMAND` wrapper configured with:

```
-o ControlMaster=auto -o ControlPath=<tmp>/%C-<target-hash> -o ControlPersist=30
-o ConnectTimeout=25 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
-o BatchMode=yes
```

The `%C-<target-hash>` path keys the control socket by OpenSSH's effective connection hash plus a
short hash of the original SSH host token, so aliases that share a host but use different SSH
identities do not reuse one another's master connection and long hostnames do not exceed Unix socket
path limits. Repos using the same SSH alias still share one connection. `ServerAlive*` makes a
silently-throttling server drop the connection instead of hanging, and `BatchMode` keeps it from
blocking on a prompt. Host-key checking is left to your SSH config. The master connections are closed
on exit.

If you already set `GIT_SSH_COMMAND` (or a repo sets `core.sshCommand`), `git-mux` layers its OpenSSH
options on top of your command instead of replacing it. If that command **already does its own
multiplexing** (`ControlMaster`, `ControlPath`, `ControlPersist`, `-S`, `-M`, or `-MM`), git-mux
doesn't double up — it steps aside and runs that repo with its command as-is (printing a note), and
multiplexes the rest as usual. This is decided per repo, so one custom repo no longer aborts the whole
batch; pass `--no-mux` to disable git-mux's multiplexing everywhere. If `GIT_SSH_COMMAND` is not set,
repo-local `core.sshCommand` and then an existing `GIT_SSH` wrapper are preserved.

For unattended runs, git-mux sets `GIT_TERMINAL_PROMPT=0` so a missing credential or host key fails
fast instead of hanging on a prompt (opt back in with `GIT_TERMINAL_PROMPT=1`), and when there's no
ssh config at all it defaults to `ssh -o BatchMode=yes`.

## Requirements

- bash (works with the macOS system bash 3.2) and OpenSSH.
- Designed and tested on macOS; should work on any Unix with OpenSSH.

## Tests

```bash
tests/git-mux-test.sh
```

## License

MIT — see [LICENSE](LICENSE).
