ARG PHP_VERSION=8.5

# ---- Base PHP image used by build and runtime stages ----
FROM php:${PHP_VERSION}-fpm-alpine AS php-base

ARG DB_DRIVERS="sqlite"
ARG EXTRA_PECL=""
ARG EXTRA_EXT=""

RUN set -eux; \
    RUNTIME_PKGS="ca-certificates curl git icu-libs libzip libpng libjpeg-turbo freetype libwebp libexif"; \
    BUILD_PKGS="icu-dev libzip-dev libpng-dev libjpeg-turbo-dev freetype-dev libwebp-dev linux-headers"; \
    PHP_EXTS="bcmath pcntl intl zip gd exif"; \
    for driver in $DB_DRIVERS; do \
        case "$driver" in \
            mysql) RUNTIME_PKGS="$RUNTIME_PKGS mariadb-connector-c"; BUILD_PKGS="$BUILD_PKGS mariadb-dev"; PHP_EXTS="$PHP_EXTS pdo_mysql" ;; \
            pgsql) RUNTIME_PKGS="$RUNTIME_PKGS libpq"; BUILD_PKGS="$BUILD_PKGS postgresql-dev"; PHP_EXTS="$PHP_EXTS pdo_pgsql" ;; \
            sqlite) RUNTIME_PKGS="$RUNTIME_PKGS sqlite-libs" ;; \
            *) echo "Unknown DB driver: $driver"; exit 1 ;; \
        esac; \
    done; \
    PECL_LIST=""; \
    for ext in $EXTRA_PECL; do \
        case "$ext" in \
            redis) PECL_LIST="$PECL_LIST redis" ;; \
            mongodb) BUILD_PKGS="$BUILD_PKGS openssl-dev"; PECL_LIST="$PECL_LIST mongodb" ;; \
            imagick) RUNTIME_PKGS="$RUNTIME_PKGS imagemagick"; BUILD_PKGS="$BUILD_PKGS imagemagick-dev"; PECL_LIST="$PECL_LIST imagick" ;; \
            memcached) RUNTIME_PKGS="$RUNTIME_PKGS libmemcached"; BUILD_PKGS="$BUILD_PKGS libmemcached-dev zlib-dev cyrus-sasl-dev"; PECL_LIST="$PECL_LIST memcached" ;; \
            *) echo "Unknown PECL extension: $ext"; exit 1 ;; \
        esac; \
    done; \
    for ext in $EXTRA_EXT; do \
        case "$ext" in \
            gmp) RUNTIME_PKGS="$RUNTIME_PKGS gmp"; BUILD_PKGS="$BUILD_PKGS gmp-dev"; PHP_EXTS="$PHP_EXTS gmp" ;; \
            soap) PHP_EXTS="$PHP_EXTS soap" ;; \
            sockets) PHP_EXTS="$PHP_EXTS sockets" ;; \
            calendar) PHP_EXTS="$PHP_EXTS calendar" ;; \
            *) echo "Unknown PHP extension: $ext"; exit 1 ;; \
        esac; \
    done; \
    apk add --no-cache $RUNTIME_PKGS; \
    apk add --no-cache --virtual .build-deps $BUILD_PKGS $PHPIZE_DEPS; \
    for pecl_ext in $PECL_LIST; do \
        pecl install "$pecl_ext"; \
        docker-php-ext-enable "$pecl_ext"; \
    done; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install $PHP_EXTS; \
    apk del .build-deps

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY --from=oven/bun:1-alpine /usr/local/bin/bun /usr/local/bin/bun

WORKDIR /var/www/html

# ---- PHP dependencies ----
FROM php-base AS composer-deps

COPY composer.json composer.lock ./

RUN --mount=type=secret,id=composer_auth,target=/var/www/html/auth.json,required=false \
    composer install \
        --no-dev \
        --no-scripts \
        --no-autoloader \
        --no-interaction \
        --no-progress \
        --prefer-dist

# ---- Frontend assets ----
FROM php-base AS assets

COPY --from=composer-deps /var/www/html/vendor ./vendor
COPY composer.json composer.lock package.json bun.lock vite.config.ts tsconfig.json components.json ./
COPY app ./app
COPY bootstrap ./bootstrap
COPY config ./config
COPY database ./database
COPY public ./public
COPY resources ./resources
COPY routes ./routes
COPY artisan ./

RUN mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
    && export APP_ENV=production APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
    && composer dump-autoload --optimize --no-dev \
    && php artisan package:discover --ansi \
    && bun install --frozen-lockfile \
    && bun run build

# ---- Production image ----
FROM php-base AS production

ARG IMAGE_SOURCE=""
LABEL org.opencontainers.image.source=${IMAGE_SOURCE}

RUN apk add --no-cache nginx

COPY . .
COPY --from=composer-deps /var/www/html/vendor ./vendor
COPY --from=assets /var/www/html/public/build ./public/build

RUN composer dump-autoload --optimize --classmap-authoritative --no-dev \
    && php artisan package:discover --ansi \
    && rm -f public/hot \
    && mkdir -p storage/app/public storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache database \
    && chmod -R ug+rwX storage bootstrap/cache database

COPY docker/php/php-prod.ini /usr/local/etc/php/conf.d/99-prod.ini
COPY docker/php/www-prod.conf /usr/local/etc/php-fpm.d/www.conf
COPY docker/nginx/nginx-prod.conf /etc/nginx/nginx.conf
COPY docker/nginx/default-prod.conf /etc/nginx/http.d/default.conf
COPY docker/entrypoint-prod.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["web"]
