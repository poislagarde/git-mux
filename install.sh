#!/usr/bin/env bash
#
# Install git-mux: symlink the script onto your PATH.
#
# Shell completion is shipped in completions/_git-mux but is NOT auto-installed —
# see "Shell completion" in the README for how to enable it (it depends on your
# fpath, which an installer can't reliably guess).
#
# Idempotent — safe to re-run (e.g. after `git pull` in this repo).
#
# Usage:
#   ./install.sh                          # script -> $HOME/.local/bin
#   GIT_MUX_BIN="$HOME/bin" ./install.sh  # override the bin dir
#
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
bin_dir="${GIT_MUX_BIN:-$HOME/.local/bin}"
target="$bin_dir/git-mux"

mkdir -p "$bin_dir"
if [ -d "$target" ] && [ ! -L "$target" ]; then
  echo "git-mux: cannot install: $target is a directory" >&2
  exit 1
fi
if [ -e "$target" ] && [ ! -L "$target" ]; then
  echo "git-mux: cannot install: $target exists and is not a symlink" >&2
  exit 1
fi
ln -sfn "$repo/git-mux" "$target"

echo "git-mux -> $target"
echo "Make sure '$bin_dir' is on your PATH, then 'git mux ...' works."
echo
echo "Shell completion (zsh) is optional and not auto-installed. Enable it by adding"
echo "this repo's completions dir to your fpath before compinit, e.g. in ~/.zshrc:"
echo
echo "    fpath=($repo/completions \$fpath)"
echo "    autoload -Uz compinit && compinit"
echo
echo "or symlink $repo/completions/_git-mux into a directory already on your \$fpath."
