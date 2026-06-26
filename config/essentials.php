<?php

declare(strict_types=1);

use NunoMaduro\Essentials\Configurables\ForceScheme;
use NunoMaduro\Essentials\Configurables\Unguard;

return [
    ForceScheme::class => env('FORCE_HTTPS', false),
    Unguard::class => true,
];
