#!/usr/bin/env bash
set -euo pipefail

# 1) убедимся, что есть ключи ssh
[[ -f test-key && -f test-key.pub ]] || ssh-keygen -t rsa -b 2048 -N "" -f test-key -q

# 2) установим bats (однажды в CI, локально — тоже однажды)
if ! command -v bats &>/dev/null; then
  echo "Installing bats-core locally…"
  git clone --depth 1 https://github.com/bats-core/bats-core.git .bats-tmp
  sudo ./.bats-tmp/install.sh /usr/local
  rm -rf .bats-tmp
fi

# 3) прогоняем все файлы tests/*.bats
bats --timing tests
