#!/usr/bin/env bash
set -euo pipefail

RUN_ID="pgclone-$(date +%s%N)"
export RUN_ID

cleanup_all() {
  docker rm -f "$(docker ps -aq --filter "label=pgclone-test-run=$RUN_ID")" 2>/dev/null || true
}

trap cleanup_all EXIT

# 1) ensure we have ssh keys
[[ -f test-key && -f test-key.pub ]] || ssh-keygen -t rsa -b 2048 -N "" -f test-key -q

# 2) install bats (once in CI, once locally)
if ! command -v bats &>/dev/null; then
  echo "Installing bats-core locally…"
  git clone --depth 1 https://github.com/bats-core/bats-core.git .bats-tmp
  sudo ./.bats-tmp/install.sh /usr/local
  rm -rf .bats-tmp
fi

# 3) run all tests in tests/*.bats
bats --timing tests
