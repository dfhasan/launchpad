# syntax=docker/dockerfile:1.7
# Golden-path image for Laravel apps (used here for SafeBrief).
# Build context = the application repository root:
#   docker build -f apps/safebrief/Dockerfile -t safebrief:local ../safebrief

# Debian variant: www-data is UID 33 (matches runAsUser in gitops/ manifests)
ARG PHP_IMAGE=serversideup/php:8.4-fpm-nginx

############################
# 1) PHP dependencies
############################
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --no-scripts --no-autoloader --prefer-dist --ignore-platform-reqs
COPY . .
RUN composer dump-autoload --no-dev --optimize --classmap-authoritative --no-scripts

############################
# 2) Front-end assets (Vite) — needs vendor/ for Ziggy
############################
FROM node:22-alpine AS assets
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY --from=vendor /app /app
RUN npm run build

############################
# 3) Runtime: nginx + php-fpm, non-root, listens on :8080
############################
FROM ${PHP_IMAGE} AS runtime
ENV PHP_OPCACHE_ENABLE=1 \
    AUTORUN_ENABLED=true \
    AUTORUN_LARAVEL_MIGRATION=true \
    AUTORUN_LARAVEL_STORAGE_LINK=true \
    LOG_CHANNEL=stderr \
    SSL_MODE=off

USER root
RUN install-php-extensions pdo_mysql bcmath intl
USER www-data

WORKDIR /var/www/html
COPY --chown=www-data:www-data --from=vendor /app /var/www/html
COPY --chown=www-data:www-data --from=assets /app/public/build /var/www/html/public/build
RUN rm -rf node_modules tests .env

EXPOSE 8080
# Laravel's built-in health route (bootstrap/app.php -> health: '/up')
HEALTHCHECK --interval=15s --timeout=3s --start-period=30s --retries=3 \
  CMD curl -fsS http://localhost:8080/up || exit 1
