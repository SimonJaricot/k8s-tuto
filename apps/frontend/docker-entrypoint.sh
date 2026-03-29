#!/bin/sh
set -e

# Substituer l'URL de l'API dans le HTML au démarrage
# API_URL est défini via une variable d'environnement Kubernetes (ConfigMap)
API_URL="${API_URL:-http://localhost:8080}"

# Injecter window.API_URL dans le fichier HTML
sed -i "s|window.API_URL || 'http://localhost:8080'|'${API_URL}'|g" \
  /usr/share/nginx/html/index.html

exec "$@"
