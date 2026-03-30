#!/bin/sh
set -e

# Substituer l'URL de l'API dans le HTML au démarrage
# API_URL est défini via une variable d'environnement Kubernetes
export API_URL="${API_URL:-http://localhost:8080}"

# envsubst remplace $API_URL dans index.html (template → fichier final)
envsubst '$API_URL' < /usr/share/nginx/html/index.html.tmpl \
  > /usr/share/nginx/html/index.html

exec "$@"
