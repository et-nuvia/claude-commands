# PHP Framework Guide

## Overview

PHP backend development with Laravel, Eloquent ORM, and modern tooling.

---

## Default Stack

| Component | Tool | Version |
|-----------|------|---------|
| Runtime | PHP | 8.3+ |
| Framework | Laravel | 11.x |
| ORM | Eloquent | Built-in |
| Testing | PHPUnit + Pest | Latest |
| Static Analysis | PHPStan | Latest |

---

## PROJECT.yaml Configuration

```yaml
languages:
  - name: php
    version: "8.3"
    root: "."

testing:
  command: "php artisan test"
  coverage_command: "php artisan test --coverage"
  min_coverage: 80

quality:
  lint_command: "vendor/bin/pint --test"
  format_command: "vendor/bin/pint"
  typecheck_command: "vendor/bin/phpstan analyse"
```

---

## Project Structure

```
├── app/
│   ├── Http/
│   │   ├── Controllers/
│   │   └── Middleware/
│   ├── Models/
│   ├── Services/
│   │   └── SecretsService.php
│   └── Providers/
├── config/
├── database/
│   ├── migrations/
│   └── seeders/
├── routes/
│   └── api.php
├── tests/
├── composer.json
├── Dockerfile
└── docker-compose.yml
```

---

## Secrets Service

```php
<?php
// app/Services/SecretsService.php

namespace App\Services;

use Illuminate\Support\Facades\Cache;
use Aws\SecretsManager\SecretsManagerClient;
use Symfony\Component\Yaml\Yaml;

class SecretsService
{
    private array $config;
    private string $backend;
    private string $appName;
    private int $ttl;

    public function __construct()
    {
        $this->loadConfig();
    }

    private function loadConfig(): void
    {
        $projectFile = base_path('PROJECT.yaml');
        if (!file_exists($projectFile)) {
            throw new \RuntimeException('PROJECT.yaml not found');
        }

        $this->config = Yaml::parseFile($projectFile);
        $this->appName = $this->config['name'];
        $this->backend = $this->config['secrets']['backend']
            ?? (PHP_OS === 'Darwin' ? 'aws' : 'infisical');
        $this->ttl = $this->config['secrets']['refresh']['interval_seconds'] ?? 300;
    }

    public function getSecretBucket(string $bucket): array
    {
        $env = env('ENVIRONMENT', 'development');
        $cacheKey = "secrets.{$this->appName}.{$env}.{$bucket}";

        return Cache::remember($cacheKey, $this->ttl, function () use ($bucket, $env) {
            if ($this->backend === 'aws') {
                return $this->fetchFromAws("{$this->appName}/{$env}/{$bucket}");
            }
            return $this->fetchFromInfisical($env, $bucket);
        });
    }

    public function getDatabaseCredentials(string $userType = 'app'): array
    {
        $db = $this->getSecretBucket('database');

        if ($userType === 'migration') {
            return [
                'host' => $db['host'],
                'port' => $db['port'],
                'database' => $db['database'],
                'username' => $db['migration_username'],
                'password' => $db['migration_password'],
            ];
        }

        return [
            'host' => $db['host'],
            'port' => $db['port'],
            'database' => $db['database'],
            'username' => $db['app_username'],
            'password' => $db['app_password'],
        ];
    }

    private function fetchFromAws(string $secretId): array
    {
        $client = new SecretsManagerClient([
            'region' => env('REGION', 'us-east-1'),
            'version' => 'latest',
        ]);

        $result = $client->getSecretValue(['SecretId' => $secretId]);
        return json_decode($result['SecretString'], true);
    }

    private function fetchFromInfisical(string $env, string $bucket): array
    {
        $client = new \GuzzleHttp\Client();
        $response = $client->get('https://secrets.turnersrus.com/api/v3/secrets', [
            'headers' => [
                'Authorization' => 'Bearer ' . env('INFISICAL_TOKEN'),
            ],
            'query' => [
                'workspaceId' => env('INFISICAL_PROJECT_ID'),
                'environment' => $env,
                'path' => "/{$this->appName}/{$bucket}",
            ],
        ]);

        $secrets = json_decode($response->getBody(), true);
        foreach ($secrets['secrets'] as $secret) {
            if ($secret['secretKey'] === 'DATA') {
                return json_decode($secret['secretValue'], true);
            }
        }
        return [];
    }
}
```

---

## Database Configuration

```php
<?php
// config/database.php

use App\Services\SecretsService;

// Get credentials from secrets (with caching)
$secrets = app(SecretsService::class);
$dbCreds = $secrets->getDatabaseCredentials('app');

return [
    'default' => env('DB_CONNECTION', 'pgsql'),

    'connections' => [
        'pgsql' => [
            'driver' => 'pgsql',
            'host' => $dbCreds['host'],
            'port' => $dbCreds['port'],
            'database' => $dbCreds['database'],
            'username' => $dbCreds['username'],
            'password' => $dbCreds['password'],
            'charset' => 'utf8',
            'prefix' => '',
            'schema' => 'public',
        ],
    ],

    // Migration connection uses migration user
    'migrations' => [
        'driver' => 'pgsql',
        'host' => $dbCreds['host'],
        'port' => $dbCreds['port'],
        'database' => $dbCreds['database'],
        'username' => env('DB_MIGRATION_USER'),  // Set at runtime
        'password' => env('DB_MIGRATION_PASS'),
    ],
];
```

---

## Migration Commands

```bash
# Create migration
php artisan make:migration create_users_table

# Run migrations (uses migration user)
DB_MIGRATION_USER=myapp_migration DB_MIGRATION_PASS=pass php artisan migrate

# Rollback
php artisan migrate:rollback

# Fresh migration (development only)
php artisan migrate:fresh --seed
```

---

## Service Provider

```php
<?php
// app/Providers/AppServiceProvider.php

namespace App\Providers;

use App\Services\SecretsService;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(SecretsService::class, function () {
            return new SecretsService();
        });
    }
}
```

---

## Dockerfile

```dockerfile
FROM php:8.3-fpm-alpine AS base

# Install extensions
RUN apk add --no-cache \
    postgresql-dev \
    && docker-php-ext-install pdo pdo_pgsql

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /app

FROM base AS builder

COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader

COPY . .
RUN composer dump-autoload --optimize

FROM base AS runner

COPY --from=builder /app /app

RUN adduser -D -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Testing stage
ARG RUN_TESTS=false
RUN if [ "$RUN_TESTS" = "true" ]; then \
    composer install --dev && \
    php artisan test; \
    fi

EXPOSE 9000
CMD ["php-fpm"]
```

---

## Commands

```bash
# Development
php artisan serve

# Testing
php artisan test
php artisan test --coverage

# Linting
vendor/bin/pint
vendor/bin/phpstan analyse

# Cache
php artisan config:cache
php artisan route:cache
php artisan view:cache

# Migrations
php artisan migrate
php artisan migrate:rollback
```

---

## Best Practices

1. **Use dependency injection** - Via constructor or service container
2. **Type hint everything** - PHP 8 attributes and types
3. **Use Eloquent accessors/mutators** - For data transformation
4. **Queue long-running tasks** - Use Laravel queues
5. **Cache aggressively** - Redis for sessions and cache
