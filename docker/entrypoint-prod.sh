#!/bin/sh
set -e

cd /var/www/html

# ---- Storage structure (volume pode montar vazio) ----
mkdir -p \
    storage/app/public \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/testing \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

chown -R www-data:www-data storage bootstrap/cache
chmod -R 775 storage bootstrap/cache

# ---- Supervisor log dir ----
mkdir -p /var/log/supervisor

# ---- .env ----
if [ ! -f .env ]; then
    cp .env.example .env
fi

# ---- APP_KEY ----
if [ -z "$APP_KEY" ] && ! grep -q "APP_KEY=base64:" .env; then
    php artisan key:generate --force
fi

# ---- Database ----
# `--isolated` usa cache lock pra impedir duas instâncias migrarem ao
# mesmo tempo (single-instance hoje, mas evita corrida se um dia o
# Traefik subir uma 2ª réplica antes do primeiro acabar). Se o cache
# driver não suportar locks, cai pro migrate normal.
php artisan migrate --force --isolated || php artisan migrate --force

# ---- Symlink storage → public/storage ----
# Sem isso, /storage/{path} retorna 404 em prod. A galeria privada e os
# uploads em storage/app/public dependem desse link. --force porque o COPY do
# build pode trazer o symlink quebrado ou ausente.
php artisan storage:link --force 2>/dev/null || true

# ---- Production seed (idempotente) ----
# ProductionSeeder usa firstOrCreate/updateOrCreate em todos os seeders
# que chama (Admin, Pastoral, Location, Position, ProductionEvent,
# SiteSetting, PrayerReactionType). Roda em todo boot sem efeito
# colateral — atualiza configs se vierem novas no deploy.
#
# NÃO usar `db:seed` puro (esse chama DatabaseSeeder que tem UserSeeder
# com Faker — quebra em --no-dev). Sempre --class explícito.
php artisan db:seed --class=ProductionSeeder --force 2>&1 | tail -20

# ---- Cache (produção) ----
php artisan optimize:clear
php artisan optimize
php artisan route:clear 2>/dev/null || true

# ---- Start services via Supervisor ----
exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
