#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="${GIT_MUX_SCRIPT:-$repo_root/git-mux}"
installer="${GIT_MUX_INSTALLER:-$repo_root/install.sh}"
root="$(mktemp -d "${TMPDIR:-/tmp}/git-mux-test.XXXXXXXXXX")"

cleanup() {
  rm -rf "$root"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain: $2" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output not to contain: $2" ;;
    *) ;;
  esac
}

capture() {
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  return "$rc"
}

make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
}

test_discovers_default_depth() {
  local base out
  base="$root/discovery"
  make_repo "$base/one"
  make_repo "$base/two"
  make_repo "$base/nested/three"

  out="$(capture "$script" -C "$base" -n status -sb)" || fail "dry-run failed"
  assert_contains "$out" "2 repos"
  assert_contains "$out" "0 SSH host(s)"
  assert_contains "$out" "multiplexing: off"
}

test_discovers_hidden_repo_directories() {
  local base out
  base="$root/hidden-discovery"
  make_repo "$base/.one"

  out="$(capture "$script" -C "$base" -n status -sb)" || fail "dry-run failed"
  assert_contains "$out" "1 repos"
  assert_contains "$out" "  $base/.one"
}

test_discovers_symlinked_repo_directories() {
  local base target out
  base="$root/repo-symlink"
  target="$root/repo-symlink-target"
  make_repo "$target"
  mkdir -p "$base"
  ln -s "$target" "$base/repo-link"

  out="$(capture "$script" -C "$base" -n status -sb)" || fail "dry-run failed"
  assert_contains "$out" "1 repos"
  assert_contains "$out" "  $base/repo-link"
}

test_deduplicates_symlinked_repo_directories() {
  local base out
  base="$root/repo-symlink-dedupe"
  make_repo "$base/repo"
  ln -s repo "$base/repo-link"

  out="$(capture "$script" -C "$base" -n status -sb)" || fail "dry-run failed"
  assert_contains "$out" "1 repos"
  assert_contains "$out" "  $base/repo"
  assert_not_contains "$out" "repo-link"
}

test_handles_recursive_directory_symlinks() {
  local base out
  base="$root/symlink-recursion"
  make_repo "$base/repo"
  mkdir -p "$base/tree"
  ln -s . "$base/tree/self-link"
  ln -s .. "$base/tree/parent-link"

  out="$(capture "$script" -C "$base" -d 5 -n status -sb)" || fail "dry-run failed"
  assert_contains "$out" "1 repos"
  assert_contains "$out" "  $base/repo"
  assert_not_contains "$out" "self-link"
  assert_not_contains "$out" "parent-link"
}

test_discovers_repos_under_symlinked_directories_once() {
  local base target out
  base="$root/symlinked-parent"
  target="$root/symlinked-parent-target"
  make_repo "$target/repo"
  mkdir -p "$base"
  ln -s "$target" "$base/group-link"

  out="$(capture "$script" -C "$base" -d 2 -n status -sb)" || fail "dry-run failed"
  assert_contains "$out" "1 repos"
  assert_contains "$out" "  $base/group-link/repo"
}

test_treats_colon_after_slash_as_local_remote() {
  local base repo out
  base="$root/local-colon"
  repo="$base/repo"
  make_repo "$repo"
  mkdir -p "$repo/remotes"
  git -C "$repo" init --bare -q "remotes/local:remote.git"
  git -C "$repo" remote add origin "remotes/local:remote.git"

  out="$(capture "$script" -C "$base" -n status -sb)" || fail "dry-run failed"
  assert_contains "$out" "0 SSH host(s)"
  assert_contains "$out" "multiplexing: off"
}

test_preserves_and_quotes_git_ssh_command() {
  local base repo sockbase out
  base="$root/ssh-command"
  repo="$base/repo"
  sockbase="$root/sock base"
  make_repo "$repo"
  mkdir -p "$sockbase"
  git -C "$repo" remote add origin "git@example.com:repo.git"
  git -C "$repo" config alias.print-ssh '!printf "%s\n%s\n" "$GIT_SSH_COMMAND" "$GIT_MUX_BASE_SSH_COMMAND"'

  out="$(capture env GIT_MUX_SOCKDIR="$sockbase" GIT_SSH_COMMAND="ssh -F /tmp/custom_config" "$script" -C "$base" print-ssh)" ||
    fail "print-ssh failed"
  assert_contains "$out" "ssh-wrapper"
  assert_contains "$out" "ssh -F /tmp/custom_config"
  assert_contains "$out" "sock\\ base"
  assert_not_contains "$out" "StrictHostKeyChecking=accept-new"
}

test_controlpath_separates_ssh_alias_identities() {
  local config sockbase work_path personal_path
  config="$root/ssh-alias-config"
  sockbase="$root/alias-socks"
  mkdir -p "$sockbase"
  printf '%s\n' \
    "Host gh-work" \
    "  HostName github.com" \
    "  User git" \
    "  IdentityFile $root/work_key" \
    "Host gh-personal" \
    "  HostName github.com" \
    "  User git" \
    "  IdentityFile $root/personal_key" > "$config"

  work_path="$(ssh -G -F "$config" -o "ControlPath=$sockbase/%C-%n" gh-work 2>/dev/null | awk '/^controlpath / {print $2; exit}')"
  personal_path="$(ssh -G -F "$config" -o "ControlPath=$sockbase/%C-%n" gh-personal 2>/dev/null | awk '/^controlpath / {print $2; exit}')"

  [ -n "$work_path" ] || fail "expected ssh -G to expand work alias ControlPath"
  [ -n "$personal_path" ] || fail "expected ssh -G to expand personal alias ControlPath"
  [ "$work_path" != "$personal_path" ] || fail "SSH aliases with different identities should not share ControlPath"
  assert_contains "$work_path" "gh-work"
  assert_contains "$personal_path" "gh-personal"
}

test_rejects_conflicting_git_ssh_command_mux_controls() {
  local base repo out rc
  base="$root/ssh-command-conflict"
  repo="$base/repo"
  make_repo "$repo"
  git -C "$repo" remote add origin "git@example.com:repo.git"

  set +e
  out="$(capture env GIT_SSH_COMMAND="ssh -o ControlMaster=no" "$script" -C "$base" -n status -sb)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected conflicting GIT_SSH_COMMAND to fail with usage error, got exit $rc"
  assert_contains "$out" "GIT_SSH_COMMAND sets SSH multiplexing controls"
  assert_contains "$out" "--no-mux"

  out="$(capture env GIT_SSH_COMMAND="ssh -o ControlMaster=no" "$script" --no-mux -C "$base" -n status -sb)" ||
    fail "--no-mux should bypass mux conflict checks"
  assert_contains "$out" "multiplexing: off"

  set +e
  out="$(capture env GIT_SSH_COMMAND="ssh -S $root/control-socket" "$script" -C "$base" -n status -sb)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected -S in GIT_SSH_COMMAND to fail with usage error, got exit $rc"
  assert_contains "$out" "GIT_SSH_COMMAND sets SSH multiplexing controls"

  set +e
  out="$(capture env GIT_SSH_COMMAND="ssh \"-S\" $root/control-socket" "$script" -C "$base" -n status -sb)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected quoted -S in GIT_SSH_COMMAND to fail with usage error, got exit $rc"
  assert_contains "$out" "GIT_SSH_COMMAND sets SSH multiplexing controls"

  set +e
  out="$(capture env GIT_SSH_COMMAND="ssh -M" "$script" -C "$base" -n status -sb)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected -M in GIT_SSH_COMMAND to fail with usage error, got exit $rc"
  assert_contains "$out" "GIT_SSH_COMMAND sets SSH multiplexing controls"

  set +e
  out="$(capture env GIT_SSH_COMMAND="ssh '-M'" "$script" -C "$base" -n status -sb)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected quoted -M in GIT_SSH_COMMAND to fail with usage error, got exit $rc"
  assert_contains "$out" "GIT_SSH_COMMAND sets SSH multiplexing controls"

  set +e
  out="$(capture env GIT_SSH_COMMAND="ssh -MM" "$script" -C "$base" -n status -sb)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected -MM in GIT_SSH_COMMAND to fail with usage error, got exit $rc"
  assert_contains "$out" "GIT_SSH_COMMAND sets SSH multiplexing controls"

  set +e
  out="$(capture env GIT_SSH_COMMAND="ssh \"-o\" ControlPath=$root/control-socket" "$script" -C "$base" -n status -sb)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected quoted -o ControlPath in GIT_SSH_COMMAND to fail with usage error, got exit $rc"
  assert_contains "$out" "GIT_SSH_COMMAND sets SSH multiplexing controls"

  out="$(capture env GIT_SSH_COMMAND="ssh -s" "$script" -C "$base" -n status -sb)" ||
    fail "lowercase -s should not be treated as an SSH mux control"
  assert_contains "$out" "multiplexing: on"
}

test_cleanup_uses_configured_git_ssh_command() {
  local base repo sockbase fake_dir fake log logged
  base="$root/ssh-cleanup-command"
  repo="$base/repo"
  sockbase="$root/socks"
  fake_dir="$root/fake ssh dir"
  fake="$fake_dir/fake ssh"
  log="$root/ssh-cleanup.log"
  make_repo "$repo"
  mkdir -p "$sockbase" "$fake_dir"
  git -C "$repo" remote add origin "ssh://git@example.com:2222/repo.git"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s %s\n" "${GIT_MUX_FAKE_MARKER:-missing}" "$*" >> "$GIT_MUX_SSH_LOG"' > "$fake"
  chmod +x "$fake"

  capture env GIT_MUX_SOCKDIR="$sockbase" GIT_MUX_SSH_LOG="$log" GIT_SSH_COMMAND="GIT_MUX_FAKE_MARKER=cleanup '$fake' -F /tmp/custom_config" "$script" -C "$base" status -sb >/dev/null ||
    fail "status run with quoted custom ssh command failed"
  [ -f "$log" ] || fail "expected cleanup to call configured ssh command"
  logged="$(cat "$log")"
  assert_contains "$logged" "cleanup"
  assert_contains "$logged" "-F /tmp/custom_config"
  assert_contains "$logged" "ControlMaster=auto"
  assert_contains "$logged" "ControlPath=$sockbase/git-mux."
  assert_contains "$logged" "%C-"
  assert_contains "$logged" "-O exit -p 2222 git@example.com"
}

test_mux_uses_git_ssh_when_command_unset() {
  local base repo fake log logged out rc
  base="$root/git-ssh-wrapper"
  repo="$base/repo"
  fake="$root/fake-git-ssh"
  log="$root/git-ssh.log"
  make_repo "$repo"
  git -C "$repo" remote add origin "git@127.0.0.1:repo.git"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$GIT_MUX_SSH_LOG"; exit 1' > "$fake"
  chmod +x "$fake"

  set +e
  out="$(capture env -u GIT_SSH_COMMAND GIT_MUX_SSH_LOG="$log" GIT_SSH="$fake" "$script" -C "$base" -r 0 ls-remote origin)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected fake GIT_SSH ls-remote to fail one repo, got exit $rc: $out"
  [ -f "$log" ] || fail "expected muxed run to invoke GIT_SSH wrapper"
  logged="$(cat "$log")"
  assert_contains "$logged" "ControlMaster=auto"
  assert_contains "$logged" "git@127.0.0.1"
}

test_mux_uses_core_ssh_command_when_env_unset() {
  local base repo fake log logged out rc
  base="$root/core-ssh-command"
  repo="$base/repo"
  fake="$root/fake-core-ssh"
  log="$root/core-ssh.log"
  make_repo "$repo"
  git -C "$repo" remote add origin "git@127.0.0.1:repo.git"
  git -C "$repo" config core.sshCommand "GIT_MUX_FAKE_MARKER=core '$fake' -F /tmp/core_config"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s %s\n" "${GIT_MUX_FAKE_MARKER:-missing}" "$*" >> "$GIT_MUX_SSH_LOG"; exit 1' > "$fake"
  chmod +x "$fake"

  set +e
  out="$(capture env -u GIT_SSH_COMMAND -u GIT_SSH GIT_MUX_SSH_LOG="$log" "$script" -C "$base" -r 0 ls-remote origin)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected fake core.sshCommand ls-remote to fail one repo, got exit $rc: $out"
  [ -f "$log" ] || fail "expected muxed run to invoke core.sshCommand"
  logged="$(cat "$log")"
  assert_contains "$logged" "core"
  assert_contains "$logged" "-F /tmp/core_config"
  assert_contains "$logged" "ControlMaster=auto"
  assert_contains "$logged" "git@127.0.0.1"
}

test_rejects_conflicting_core_ssh_command_mux_controls() {
  local base repo out rc
  base="$root/core-ssh-command-conflict"
  repo="$base/repo"
  make_repo "$repo"
  git -C "$repo" remote add origin "git@example.com:repo.git"
  git -C "$repo" config core.sshCommand "ssh '-S' $root/control-socket"

  set +e
  out="$(capture env -u GIT_SSH_COMMAND -u GIT_SSH "$script" -C "$base" -n status -sb)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected conflicting core.sshCommand to fail with usage error, got exit $rc"
  assert_contains "$out" "core.sshCommand in $repo sets SSH multiplexing controls"
  assert_contains "$out" "--no-mux"
}

test_git_ssh_command_env_assignments_work_with_mux() {
  local base repo fake log logged out rc
  base="$root/ssh-command-env-assignment"
  repo="$base/repo"
  fake="$root/fake-env-ssh"
  log="$root/env-ssh.log"
  make_repo "$repo"
  git -C "$repo" remote add origin "git@127.0.0.1:repo.git"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s %s\n" "${GIT_MUX_FAKE_MARKER:-missing}" "$*" >> "$GIT_MUX_SSH_LOG"; exit 1' > "$fake"
  chmod +x "$fake"

  set +e
  out="$(capture env GIT_MUX_SSH_LOG="$log" GIT_SSH_COMMAND="GIT_MUX_FAKE_MARKER=actual '$fake'" "$script" -C "$base" -r 0 ls-remote origin)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected fake env-assignment SSH command to fail one repo, got exit $rc: $out"
  [ -f "$log" ] || fail "expected muxed run to invoke GIT_SSH_COMMAND with env assignment"
  logged="$(cat "$log")"
  assert_contains "$logged" "actual"
  assert_contains "$logged" "ControlMaster=auto"
  assert_contains "$logged" "git@127.0.0.1"
}

test_controlpath_uses_bounded_alias_hash() {
  local base repo fake log long_host logged control_path actual_len
  base="$root/long-controlpath"
  repo="$base/repo"
  fake="$root/fake-long-host-ssh"
  log="$root/long-host-ssh.log"
  long_host="git@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example.com"
  make_repo "$repo"
  git -C "$repo" remote add origin "$long_host:repo.git"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$GIT_MUX_SSH_LOG"' > "$fake"
  chmod +x "$fake"

  capture env GIT_MUX_SSH_LOG="$log" GIT_SSH_COMMAND="$fake" "$script" -C "$base" status -sb >/dev/null ||
    fail "status run with long SSH host failed"
  [ -f "$log" ] || fail "expected cleanup to call configured ssh command"
  logged="$(cat "$log")"
  control_path="$(printf '%s\n' "$logged" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^ControlPath=/) {sub(/^ControlPath=/, "", $i); print $i; exit}}')"
  [ -n "$control_path" ] || fail "expected fake SSH log to include ControlPath"
  assert_not_contains "$control_path" "$long_host"
  actual_len=$((${#control_path} - 2 + 40))
  [ "$actual_len" -le 100 ] || fail "expected expanded ControlPath <= 100 bytes, got $actual_len: $control_path"
}

test_does_not_retry_permanent_unable_to_access() {
  local base repo out rc
  base="$root/permanent-error"
  repo="$base/repo"
  make_repo "$repo"
  git -C "$repo" config alias.fake403 '!printf "%s\n" "fatal: unable to access '\''https://example.test/repo.git/'\'': The requested URL returned error: 403" >&2; exit 128'

  set +e
  out="$(capture "$script" -C "$base" -r 1 -b 0 fake403)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected one failed repo, got exit $rc"
  assert_contains "$out" "FAILED"
  assert_not_contains "$out" "retry 1/1"
}

test_does_not_retry_permanent_ssh_repo_error() {
  local base repo out rc
  base="$root/permanent-ssh-error"
  repo="$base/repo"
  make_repo "$repo"
  git -C "$repo" config alias.fakeperm '!printf "%s\n" "ERROR: Repository not found." "fatal: Could not read from remote repository." "Please make sure you have the correct access rights and the repository exists." >&2; exit 128'

  set +e
  out="$(capture "$script" -C "$base" -r 1 -b 0 fakeperm)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected one failed repo, got exit $rc"
  assert_contains "$out" "FAILED"
  assert_not_contains "$out" "retry 1/1"
}

test_retries_transient_transport_errors() {
  local base repo out rc
  base="$root/transient-error"
  repo="$base/repo"
  make_repo "$repo"
  git -C "$repo" config alias.faketimeout '!printf "%s\n" "Connection to github.com port 22 timed out" >&2; exit 128'

  set +e
  out="$(capture "$script" -C "$base" -r 1 -b 0 faketimeout)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected one failed repo, got exit $rc"
  assert_contains "$out" "retry 1/1"
}

test_retries_large_transient_transport_errors() {
  local base repo out rc
  base="$root/large-transient-error"
  repo="$base/repo"
  make_repo "$repo"
  git -C "$repo" config alias.bigtimeout '!printf "%s\n" "Connection to github.com port 22 timed out" >&2; i=0; while [ "$i" -lt 5000 ]; do printf "%080d\n" "$i" >&2; i=$((i + 1)); done; exit 128'

  set +e
  out="$(capture "$script" -C "$base" -r 1 -b 0 bigtimeout)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected one failed repo, got exit $rc"
  assert_contains "$out" "retry 1/1"
}

test_dry_run_does_not_invoke_ssh_command() {
  local base repo fake log out
  base="$root/dry-run-no-ssh"
  repo="$base/repo"
  fake="$root/fake-dry-run-ssh"
  log="$root/dry-run-ssh.log"
  make_repo "$repo"
  git -C "$repo" remote add origin "ssh://git@example.com:2222/repo.git"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$GIT_MUX_SSH_LOG"' > "$fake"
  chmod +x "$fake"

  out="$(capture env GIT_MUX_SSH_LOG="$log" GIT_SSH_COMMAND="$fake" "$script" -C "$base" -n status -sb)" ||
    fail "dry-run failed"
  assert_contains "$out" "multiplexing: on"
  [ ! -e "$log" ] || fail "dry-run should not invoke configured SSH command"
}

test_git_ssh_command_inspection_has_no_shell_side_effects() {
  local base repo side cmd out
  base="$root/ssh-command-no-eval"
  repo="$base/repo"
  side="$root/eval-side-effect"
  make_repo "$repo"
  git -C "$repo" remote add origin "git@example.com:repo.git"
  cmd="ssh \$(touch '$side')"

  out="$(capture env GIT_SSH_COMMAND="$cmd" "$script" -C "$base" -n status -sb)" ||
    fail "dry-run with shell-like GIT_SSH_COMMAND failed"
  assert_contains "$out" "multiplexing: on"
  [ ! -e "$side" ] || fail "GIT_SSH_COMMAND inspection executed shell substitution"
}

test_rejects_unknown_front_options() {
  local base out rc
  base="$root/unknown-option"
  make_repo "$base/repo"

  set +e
  out="$(capture "$script" -C "$base" -xyz status)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expected usage error, got exit $rc"
  assert_contains "$out" "unknown option: -xyz"
  assert_not_contains "$out" "FAILED"
}

test_installer_rejects_directory_target() {
  local bin_dir out rc
  bin_dir="$root/install-bin"
  mkdir -p "$bin_dir/git-mux"

  set +e
  out="$(capture env GIT_MUX_BIN="$bin_dir" "$installer")"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected installer to reject directory target, got exit $rc"
  assert_contains "$out" "$bin_dir/git-mux is a directory"
}

test_installer_rejects_regular_file_target() {
  local bin_dir target out rc content
  bin_dir="$root/install-regular-file-bin"
  target="$bin_dir/git-mux"
  mkdir -p "$bin_dir"
  printf '%s\n' "do not replace" > "$target"

  set +e
  out="$(capture env GIT_MUX_BIN="$bin_dir" "$installer")"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected installer to reject regular file target, got exit $rc"
  assert_contains "$out" "$target exists and is not a symlink"
  [ ! -L "$target" ] || fail "installer replaced regular file with a symlink"
  content="$(cat "$target")"
  assert_contains "$content" "do not replace"
}

test_discovers_default_depth
test_discovers_hidden_repo_directories
test_discovers_symlinked_repo_directories
test_deduplicates_symlinked_repo_directories
test_handles_recursive_directory_symlinks
test_discovers_repos_under_symlinked_directories_once
test_treats_colon_after_slash_as_local_remote
test_preserves_and_quotes_git_ssh_command
test_controlpath_separates_ssh_alias_identities
test_rejects_conflicting_git_ssh_command_mux_controls
test_cleanup_uses_configured_git_ssh_command
test_mux_uses_git_ssh_when_command_unset
test_mux_uses_core_ssh_command_when_env_unset
test_rejects_conflicting_core_ssh_command_mux_controls
test_git_ssh_command_env_assignments_work_with_mux
test_controlpath_uses_bounded_alias_hash
test_does_not_retry_permanent_unable_to_access
test_does_not_retry_permanent_ssh_repo_error
test_retries_transient_transport_errors
test_retries_large_transient_transport_errors
test_dry_run_does_not_invoke_ssh_command
test_git_ssh_command_inspection_has_no_shell_side_effects
test_rejects_unknown_front_options
test_installer_rejects_directory_target
test_installer_rejects_regular_file_target

printf 'ok - git-mux regression tests\n'
