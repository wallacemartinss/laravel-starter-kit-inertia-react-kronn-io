# Infraestrutura Docker — `pascom`

> **Para humanos e agentes de IA.** Este documento descreve a arquitetura de
> containerização do app **pascom** (Paróquia São Benedito) e os pontos de
> decisão em aberto. **Antes de alterar qualquer arquivo, leia a seção
> [§12 Regras para alterar com segurança](#12-regras-para-alterar-com-seguranca).**
>
> Última atualização relevante: migração do frontend de **Filament → Laravel +
> Inertia.js + React** (baseline **CSR**). Estado em [§10](#10-estado-da-migracao-filament--inertia--react).

---

## 1. O que é este repositório

Este diretório contém **apenas o scaffolding de infraestrutura** (Docker, CI,
configs de servidor) do app Laravel `pascom`. **O código-fonte da aplicação NÃO
está aqui** — `composer.json`, `package.json`, `app/`, `resources/`,
`vite.config.js`, `tailwind.config.js`, `routes/` vivem no repositório da
aplicação. Vários pontos de decisão abaixo dependem desses arquivos externos.

Stack alvo: **PHP 8.4-fpm-alpine**, **PostgreSQL**, **Redis**, **Laravel
Horizon** (filas), **Soketi/Echo** (websockets), **Spatie MediaLibrary**,
uploads para **S3**, **PWA**, e front em **Inertia + React**.

---

## 2. Visão geral da arquitetura

```
                          ┌────────────────────────────────────────────┐
   Cloudflare ──► Traefik ─►            Container de PRODUÇÃO            │
   (edge)        (overlay) │   (imagem única, php:8.4-fpm-alpine)       │
                           │                                            │
                           │   supervisord (PID 1)                      │
                           │   ├─ nginx        :80  ──► PHP-FPM :9000   │
                           │   ├─ php-fpm      127.0.0.1:9000           │
                           │   ├─ horizon      (filas Redis)            │
                           │   └─ scheduler    (schedule:work)          │
                           │                                            │
                           │   Volume: storage/  +  bootstrap/cache/    │
                           └────────────────────────────────────────────┘
                                          │
                                          ▼
                          PostgreSQL · Redis · S3 · Soketi (serviços externos)
```

A imagem de **produção é autossuficiente**: roda nginx + php-fpm + horizon +
scheduler no mesmo container, orquestrados por Supervisor. O ambiente de **dev**
(configs `*.conf` sem sufixo `-prod`) assume containers separados via
`docker-compose` (não versionado aqui) com bind-mount do projeto.

---

## 3. Mapa de arquivos

| Arquivo | Papel | Ambiente |
|---|---|---|
| `Dockerfile` | Build multi-stage → imagem de produção | prod |
| `.dockerignore` | Exclui `.env`, `vendor`, `node_modules`, `public/build`, `public/hot`, etc. | prod |
| `docker/entrypoint-prod.sh` | Boot de produção: migrate, seed, cache, supervisord | prod |
| `docker/entrypoint.sh` | Boot de dev: só `optimize:clear`, depois `exec "$@"` | dev |
| `docker/php/php-prod.ini` | PHP tunado p/ prod (OPcache+JIT+preload, segurança) | prod |
| `docker/php/php.ini` | PHP dev (OPcache com hot-reload) | dev |
| `docker/php/www-prod.conf` | Pool PHP-FPM `static`, 20 children | prod |
| `docker/php/preload-prod.php` | OPcache preload de classes hot do Laravel | prod |
| `docker/nginx/nginx-prod.conf` | nginx global: gzip, cache de FD, buffers FastCGI | prod |
| `docker/nginx/nginx.conf` | nginx global mínimo | dev |
| `docker/nginx/default-prod.conf` | vhost: rate-limit, bloqueio de bots, real-IP CF, assets, PHP | prod |
| `docker/nginx/default.conf` | vhost mínimo (`fastcgi_pass pascom:9000`) | dev |
| `docker/supervisor/supervisord-prod.conf` | php-fpm, horizon, scheduler, nginx | prod |
| `docker/supervisor/supervisord.conf` | php-fpm, horizon, schedule-worker, env-watcher | dev |
| `.github/workflows/docker-publish.yml` | Build & push para GHCR | CI |

> `docker.conf` (registry de extensões para um `deploy.sh` legado) foi
> **removido** — era órfão; o CI não o usava.

---

## 4. Build multi-stage (`Dockerfile`)

```
Stage 1: composer-deps   (php:8.4-fpm-alpine)
  └─ composer install --no-dev --no-scripts --no-autoloader
     (auth.json injetado como BuildKit secret, required=false)

Stage 2: assets          (node:22-alpine)
  └─ npm install ; COPY vite.config.js resources app vendor ; npm run build
     (gera public/build com os bundles React/Inertia)

Stage 3: final           (php:8.4-fpm-alpine)
  ├─ extensões configuráveis (ver §5)
  ├─ COPY . .  +  vendor (do stage 1)  +  public/build (do stage 2)
  ├─ composer dump-autoload --optimize + post-autoload-dump
  ├─ chown storage/bootstrap-cache/database
  ├─ COPY configs (php-prod.ini, www-prod.conf, nginx, supervisor)
  └─ ENTRYPOINT docker/entrypoint-prod.sh ; EXPOSE 80
```

**Pontos sensíveis do build:**
- O `composer dump-autoload` (sem `--no-scripts`) dispara `post-autoload-dump`
  do `composer.json`. Se houver scripts de Filament/Livewire lá, **o build
  quebra** (ver [§11](#11-pontos-de-decisao-em-aberto-dependem-do-repo-da-app)).
- O stage `assets` roda em **node puro, sem PHP/artisan**. Qualquer plugin Vite
  que invoque `php artisan` (ex.: **Wayfinder**) **falha** aqui.

---

## 5. Extensões configuráveis (build args)

O stage final monta as extensões PHP via 3 build args (case-statements no
Dockerfile). Adicionar uma extensão nova = adicionar um `case` correspondente.

| Build arg | Valores suportados | Default CI |
|---|---|---|
| `DB_DRIVERS` | `mysql` · `pgsql` · `sqlite` | `pgsql` |
| `EXTRA_PECL` | `redis` · `mongodb` · `imagick` · `memcached` | `redis` |
| `EXTRA_EXT` | `gmp` · `soap` · `sockets` · `calendar` | *(vazio)* |

Sempre instaladas (base Laravel): `opcache bcmath pcntl intl zip gd exif
mbstring curl xml`.

---

## 6. Dev vs Produção

| | **Dev** (compose, bind-mount) | **Prod** (imagem) |
|---|---|---|
| Root da app | `/var/www` | `/var/www/html` |
| Topologia | nginx e php-fpm em **containers separados** (`fastcgi_pass pascom:9000`) | **tudo num container** (`127.0.0.1:9000`) |
| Entrypoint | `optimize:clear` apenas | migrate + seed + cache + supervisord |
| OPcache | `validate_timestamps=1` (hot-reload) | `validate_timestamps=0` + JIT + preload |
| Extras supervisor | `env-watcher` (inotify no `.env`) | `nginx` |
| Erros PHP | `display_errors=On` | `display_errors=Off`, log only |

---

## 7. Serviços em runtime (Supervisor — produção)

`docker/supervisor/supervisord-prod.conf` sobe (todos `autorestart=true`):

1. **php-fpm** (`php-fpm -F`) — FastCGI em `127.0.0.1:9000`.
2. **nginx** (`daemon off`) — serve `:80`.
3. **horizon** (`artisan horizon`, user `www-data`) — workers de fila Redis.
4. **scheduler** (`artisan schedule:work`, user `www-data`) — cron do Laravel.

> Sem o `scheduler`, todo `Schedule::command()/job()` em `routes/console.php`
> **silenciosamente nunca dispara**. Sem o `horizon`, filas não processam.

---

## 8. Fluxo de request (nginx produção)

`docker/nginx/default-prod.conf`, em ordem:

1. **Real-IP** — desembrulha `X-Forwarded-For` confiando no overlay
   (Swarm/Traefik) + faixas Cloudflare; `real_ip_recursive on`. Mantenha as
   faixas CF em sincronia com `config/cloudflare-ips.php` (no repo da app).
2. **Bloqueios** — `$bad_bot` (scanners, scrapers, UA vazio), `$bad_method`
   (TRACE/TRACK/DEBUG/CONNECT), paths sensíveis (`.env`, `.git`, `wp-admin`…),
   extensões de backup/shell.
3. **Rate-limit por rota** — zonas `general` (10r/s), `login` (5r/min),
   `api` (30r/s). Rotas: auth, `/api/`, upload S3 de fotos, `/broadcasting/auth`.
4. **PWA** — `= /sw.js` e `= /manifest.webmanifest` servidos pelo Laravel
   (controllers dinâmicos), não como arquivo estático.
5. **Static assets** — `^/build/assets/...` (1y immutable, inclui `.mjs` +
   imagens com hash do JSX), imagens, fontes, css/js.
6. **PHP** — `\.php$` → FastCGI; bloqueia PHP em `/uploads|/storage`.
7. **Health** — `= /health` → `200 "OK"` (para Traefik/LB).

> **Inertia não precisa de rota especial.** Navegações Inertia são XHR para
> rotas Laravel normais com o header `X-Inertia`, servidas pelo `location /`.
> (Por isso o antigo bloco `/livewire-<hash>/` foi removido.)

---

## 9. PHP / OPcache / segurança (`php-prod.ini`)

- **OPcache**: `memory_consumption=512`, `jit=tracing`, `jit_buffer_size=128M`,
  `validate_timestamps=0` (recompila só no deploy/restart).
- **Preload ativo**: `opcache.preload=/var/www/html/docker/php/preload-prod.php`
  (`preload_user=www-data`). Carrega classes hot do framework na memória
  compartilhada no boot do FPM.
- **`disable_functions`**: shell-exec family bloqueada; **`proc_open` e
  `curl_exec` ficam habilitados** (Horizon/scheduler usam `proc_open`; Guzzle/
  S3/Pusher usam o handler cURL).
- **`open_basedir = /var/www/html:/tmp:/var/log`** — qualquer caminho fora disso
  dá erro silencioso.
- **FPM**: `pm=static`, `max_children=20`, `memory_limit=512M` (teto, não uso
  real). Dimensione conforme a RAM do host.

---

## 10. Estado da migração Filament → Inertia + React

**Baseline escolhido: CSR (client-side rendering).** A imagem **não** precisou
mudar de arquitetura.

### Já feito nesta infra (de-Filament-ização)
- ❌ Removido o bloco de pre-cache do `Dockerfile` (`icons:cache` +
  `filament:cache-components`) — era **BUILD-FATAL** sem Filament.
- ❌ Removidas as mesmas chamadas mortas do `entrypoint-prod.sh`.
- ❌ Removido o bloco de rate-limit `/livewire` do nginx (dead config).
- ✅ Regex de `/build/assets` ampliado para o output do React (`.mjs` + imagens
  com hash).
- ✅ Comentários que citavam Filament atualizados.

### Mantido de propósito (conservador)
- `COPY app ./app` e `COPY --from=composer-deps vendor` no stage `assets` —
  remover é otimização, mas **quebra se o build usar Ziggy (alias pro vendor) ou
  Tailwind escanear `app/`**. Decisão depende do repo da app ([§11](#11-pontos-de-decisao-em-aberto-dependem-do-repo-da-app)).
- `php artisan route:clear` no entrypoint — não é específico de Filament;
  mexer mudaria comportamento de runtime sem validação.

---

## 11. Pontos de decisão em aberto (dependem do repo da APP)

> ⚠️ Estes **não podem ser resolvidos neste repositório** — exigem editar o repo
> da aplicação. Os três primeiros são **risco de BUILD-FATAL**.

1. **`composer.json` → `post-autoload-dump` / `post-update-cmd`:** remover
   qualquer `@php artisan filament:*`, `livewire:*` ou `icons:*`. Senão o
   `composer dump-autoload` do Dockerfile quebra o build.
2. **`vite.config.js` → Ziggy ou Wayfinder?**
   - **Ziggy** com alias para `vendor/tightenco/ziggy` → **manter** o
     `COPY vendor` no stage assets (já está mantido).
   - **Wayfinder** (`@laravel/vite-plugin-wayfinder`) → roda `php artisan` no
     build e **falha no stage node sem PHP**; exige pré-gerar rotas num stage com
     PHP e copiar, ou instalar php-cli no stage assets.
   - Ziggy **v2** (`ziggy-js` via npm) não precisa de vendor → aí dá pra remover
     os COPYs.
3. **`tailwind.config.js` → content globs:** confirmar se há `./vendor/**` ou
   `./app/**`. Em app React/Inertia a paginação é JSX, então globs de vendor
   tendem a ser inócuos — mas verifique antes de remover os COPYs.
4. **Rotas cacheáveis:** `php artisan optimize` (no entrypoint) roda `route:cache`
   sem guard (`set -e`). Garanta rotas em controllers/invokables/`Route::inertia`
   (sem closures) ou o boot aborta.
5. **CI composer-auth (`docker-publish.yml`):** o plumbing de `auth.json`/
   `COMPOSER_AUTH` existia só para o tema privado `devletes/filament-orbit-theme`
   (kronn.io). Se não houver **nenhum** pacote privado restante, dá para apagar:
   a step "Write composer auth", o bloco `secret-files:` e o secret no GitHub.
   O mount é `required=false`, então é **inócuo** se deixado.

### Decisão CSR vs SSR (arquitetural)
**SSR de Inertia exige Node.js na imagem de produção** (hoje `php:8.4-fpm-alpine`
**sem Node**). Ativar SSR depois precisa de 3 adições:
1. No stage `assets`: também `vite build --ssr` + `COPY --from=assets
   /app/bootstrap/ssr ./bootstrap/ssr`.
2. **Node runtime na imagem final** (binário Node, layer base node, ou
   container sidecar separado).
3. Programa supervisor `command=php artisan inertia:start-ssr` (porta `13714`,
   user `www-data`) no `supervisord-prod.conf`.

Nenhuma edição atual bloqueia ativar SSR depois.

---

## 12. Regras para alterar com segurança

**Para qualquer agente de IA ou humano editando esta infra:**

1. **Dev vs prod são pares.** Arquivos com sufixo `-prod` vão para a imagem; os
   sem sufixo são para o compose de dev. Ao mudar comportamento, verifique se o
   par precisa do mesmo ajuste. Paths divergem: **dev=`/var/www`,
   prod=`/var/www/html`**.
2. **Nada de comando artisan de Filament/Livewire/blade-icons** (`filament:*`,
   `icons:cache`) — o app não os tem mais. Em `RUN` do Dockerfile encadeado com
   `&&`, um comando inexistente **quebra o build inteiro**.
3. **O stage `assets` não tem PHP.** Não adicione passos que chamem `php`/
   `artisan` ali.
4. **`open_basedir`** restringe a `/var/www/html:/tmp:/var/log`. Código/volumes
   fora disso falham silenciosamente.
5. **Não cacheie config no build.** `config:cache` em build-time congela
   `.env.example`. O cache real é feito pelo `entrypoint-prod.sh` em runtime.
6. **Confirme premissas no repo da app** antes de otimizar o stage assets
   (ver §11) — `vite.config.js` e `tailwind.config.js` mandam.
7. **Extensão PHP nova** = adicionar `case` no Dockerfile **e** passar no build
   arg (`DB_DRIVERS`/`EXTRA_PECL`/`EXTRA_EXT`) + no CI.
8. **Faixas Cloudflare** no nginx devem espelhar `config/cloudflare-ips.php`.
9. **Valide antes de concluir:** `nginx -t` (chaves balanceadas), `sh -n` nos
   entrypoints, e `grep -riE 'filament|livewire|icons:cache'` deve voltar só
   comentários.

---

## 13. CI/CD (`docker-publish.yml`)

- **Gatilhos:** push em `main`, tags `v*.*.*`, ou `workflow_dispatch`.
- **Registry:** GHCR. **`IMAGE_NAME` derivado de `${{ github.repository }}`**
  (renomear o repo renomeia a imagem; `metadata-action` faz lowercase).
- **Build args fixos no CI:** `DB_DRIVERS=pgsql EXTRA_PECL=redis EXTRA_EXT=`.
- **Secret `COMPOSER_AUTH`** → arquivo → `secret-files` (BuildKit secret, não
  vaza em layer). Ver [§11.5](#11-pontos-de-decisao-em-aberto-dependem-do-repo-da-app).
- **Cache:** `type=gha` (mode=max). **Plataforma:** `linux/amd64`.
