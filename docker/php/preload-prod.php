<?php

/**
 * OPcache Preloading Script - Production
 *
 * Carrega classes frequentes do Laravel na memória compartilhada do OPcache
 * no boot do PHP-FPM. Elimina I/O de disco por request para essas classes.
 *
 * Requisitos:
 *   - opcache.preload = /var/www/html/docker/php/preload-prod.php
 *   - opcache.preload_user = www-data
 */

require_once '/var/www/html/vendor/autoload.php';

// Framework core
$preloadPaths = [
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Foundation',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Routing',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Http',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Support',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Database',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Collections',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Container',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Pipeline',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Events',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Cache',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Session',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/View',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Auth',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Validation',
    '/var/www/html/vendor/laravel/framework/src/Illuminate/Log',
];

foreach ($preloadPaths as $path) {
    if (!is_dir($path)) {
        continue;
    }

    $files = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($path, RecursiveDirectoryIterator::SKIP_DOTS)
    );

    foreach ($files as $file) {
        if ($file->getExtension() !== 'php') {
            continue;
        }

        try {
            opcache_compile_file($file->getRealPath());
        } catch (Throwable) {
            // Silently skip files that can't be preloaded (interfaces with unmet deps, etc.)
        }
    }
}
