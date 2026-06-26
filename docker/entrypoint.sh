#!/usr/bin/env bash
# DevHub Generated — dev container entrypoint.
#
# Order of operations on every container start (down+up, restart, recreate):
#   1. Wait briefly for the bind-mounted project to be visible.
#   2. If this is a Laravel project, run `php artisan optimize:clear` to drop
#      stale config/route/view/event caches. This is what lets fresh boots
#      pick up changes the user made to .env without manual artisan calls.
#   3. exec the CMD passed by Dockerfile (supervisord by default).
#
# Failures here are logged but never abort the boot — the container should
# still come up so the user can fix things from inside it.

set -e

PROJECT_DIR="${PROJECT_DIR:-/var/www}"

clear_laravel_caches() {
  if [ ! -f "${PROJECT_DIR}/artisan" ]; then
    echo "[entrypoint] no artisan at ${PROJECT_DIR} — skipping cache clear"
    return 0
  fi
  echo "[entrypoint] running php artisan optimize:clear in ${PROJECT_DIR}"
  # optimize:clear runs config/route/view/event/compiled clears in one go.
  # 2>&1 || true — never let a Laravel boot error block container startup;
  # the user needs to be able to docker exec in and fix it.
  php "${PROJECT_DIR}/artisan" optimize:clear 2>&1 || \
    echo "[entrypoint] optimize:clear returned non-zero (continuing anyway)"
}

clear_laravel_caches

exec "$@"
