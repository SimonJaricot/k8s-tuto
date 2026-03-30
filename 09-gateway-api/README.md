# Module 09 — Gateway API

**Objectif** : exposer le frontend et l'API Go à l'extérieur du cluster en utilisant la Gateway API de Kubernetes, implémentée nativement par Cilium. Tester le frontend complet depuis un navigateur.

---

## Ingress vs Gateway API

L'**Ingress** est la ressource historique pour exposer des services HTTP. La **Gateway API** est son successeur, plus expressif et mieux structuré.

| Aspect | Ingress | Gateway API |
|--------|---------|-------------|
| Ressource | `Ingress` | `Gateway` + `HTTPRoute` |
| Rôles séparés | Non | Oui (infra vs app) |
| TLS | Basique | Avancé (par route) |
| Protocoles | HTTP/HTTPS | HTTP, TCP, TLS, gRPC |
| Filtres de requête | Limités | Riches (rewrite, header, mirror…) |
| Support Cilium | Via annotations | Natif (1.13+) |

---

## Les ressources de la Gateway API

```
GatewayClass   ←── "qui" gère les Gateways (Cilium, nginx, istio…)
     │
     ▼
Gateway        ←── point d'entrée réseau (IP, ports, TLS)
     │
     ├── HTTPRoute   ←── règles de routage HTTP (host, path, headers)
     ├── TCPRoute    ←── routage TCP brut
     └── TLSRoute    ←── routage TLS passthrough
```

---

## Activer la Gateway API avec Cilium

La Gateway API nécessite l'installation des CRDs (Custom Resource Definitions) en plus de l'activation dans Cilium.

### Installer les CRDs Gateway API

```bash
# CRDs standard Gateway API (channel experimental pour TCPRoute)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml
```

### Activer dans Cilium

```bash
helm upgrade cilium cilium/cilium \
  --version 1.19.2 \
  --namespace kube-system \
  --reuse-values \
  --set gatewayAPI.enabled=true
```

Vérifier :

```bash
kubectl get gatewayclass
```

```
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       30s
```

---

## GatewayClass

La `GatewayClass` est créée automatiquement par Cilium lors de l'activation. Elle identifie Cilium comme contrôleur des Gateways.

```bash
kubectl describe gatewayclass cilium
```

```
Name:         cilium
Controller:   io.cilium/gateway-controller
Status:       Accepted
```

---

## Architecture : deux hostnames séparés

On expose deux hostnames distincts sur la même Gateway :

- `app.local` → Service `frontend` (ns/frontend)
- `api.local` → Service `api` (ns/api)

Le frontend appelle l'API via `http://api.local` — une URL accessible depuis le navigateur, pas depuis l'intérieur du cluster.

```
Navigateur
    │
    ├── http://app.local  →  Gateway  →  frontend:80  (ns/frontend)
    └── http://api.local  →  Gateway  →  api:8080     (ns/api)
                                               │
                                               ▼
                                       postgres:5432 (ns/database)
```

---

## Gateway

```yaml
# manifests/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: frontend
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-accessible: "true"   # Seuls les namespaces autorisés
```

```bash
kubectl apply -f 09-gateway-api/manifests/gateway.yaml

# Attendre que la Gateway obtienne une IP
kubectl get gateway main-gateway -n frontend -w
```

```
NAME           CLASS    ADDRESS        PROGRAMMED   AGE
main-gateway   cilium   172.18.0.240   True         15s
```

> Avec kind, l'adresse assignée est une IP Docker interne. On utilisera `kubectl port-forward` pour y accéder depuis la machine hôte.

---

## HTTPRoute — Exposer le frontend

```yaml
# manifests/frontend-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: frontend-route
  namespace: frontend
spec:
  parentRefs:
    - name: main-gateway
      namespace: frontend
  hostnames:
    - "app.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 80
```

---

## HTTPRoute — Exposer l'API Go

```yaml
# manifests/api-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: api
spec:
  parentRefs:
    - name: main-gateway
      namespace: frontend
  hostnames:
    - "api.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: api
          port: 8080
```

> Les HTTPRoutes sont créées dans le namespace du Service qu'elles exposent, pas nécessairement dans le namespace de la Gateway.

---

## Permettre aux namespaces d'accéder à la Gateway

La Gateway a `allowedRoutes.namespaces.from: Selector` — seuls les namespaces avec le label `gateway-accessible: "true"` peuvent y attacher des routes.

```bash
kubectl label namespace api gateway-accessible=true
kubectl label namespace frontend gateway-accessible=true
```

---

## Mettre à jour l'API_URL du frontend

Jusqu'ici, le frontend utilisait `http://api.api.svc.cluster.local:8080` comme `API_URL` — une URL interne au cluster, non résolvable par un navigateur. Maintenant que la Gateway expose l'API sous `http://api.local`, on met à jour le Deployment :

```bash
kubectl apply -f 09-gateway-api/manifests/frontend-api-url-patch.yaml
```

Ce patch strategic merge met à jour uniquement la variable `API_URL` du conteneur `frontend` :

```yaml
# manifests/frontend-api-url-patch.yaml
spec:
  template:
    spec:
      containers:
        - name: frontend
          env:
            - name: API_URL
              value: "http://api.local"
```

Le Pod frontend redémarre automatiquement avec la nouvelle valeur.

---

## NetworkPolicies — Autoriser le trafic depuis la Gateway

Cilium crée un pod Envoy proxy dans le namespace de la Gateway (`frontend`) pour gérer le trafic. Ce pod doit pouvoir atteindre les Services `frontend` et `api`.

```bash
kubectl apply -f 09-gateway-api/manifests/gateway-network-policies.yaml
```

Vérifier que les nouvelles policies sont valides :

```bash
kubectl get ciliumnetworkpolicy -A
```

Les policies `allow-from-gateway` dans `ns/frontend` et `ns/api` apparaissent avec `VALID: True`.

---

## Tester depuis la machine hôte

### Étape 1 — Configurer /etc/hosts

Ajouter les hostnames locaux pour résoudre `app.local` et `api.local` vers localhost :

```bash
echo "127.0.0.1 app.local api.local" | sudo tee -a /etc/hosts
```

> Pour nettoyer après le tutoriel : supprimer la ligne ajoutée dans `/etc/hosts`.

### Étape 2 — Port-forward sur la Gateway

```bash
kubectl port-forward -n frontend svc/cilium-gateway-main-gateway 80:80 &
```

> Le nom du Service créé par Cilium pour la Gateway suit le format `cilium-gateway-<gateway-name>`.

### Étape 3 — Tester l'API

```bash
curl http://api.local/users
```

```json
[{"id":1,"name":"Charlie","email":"charlie@example.com"}]
```

```bash
curl http://api.local/healthz
```

```json
{"status":"ok"}
```

### Étape 4 — Tester le frontend dans le navigateur

Ouvrir `http://app.local` dans le navigateur. La liste des utilisateurs s'affiche, le formulaire de création fonctionne.

> **Pourquoi ça marche maintenant ?** Le browser envoie `GET /users` vers `http://api.local` — qui est résolu par `/etc/hosts` vers `127.0.0.1`, puis redirigé par `port-forward` vers le Service Gateway dans le cluster, puis routé par la HTTPRoute `api-route` vers le Service `api`.

---

## Filtres HTTPRoute (fonctionnalités avancées)

La Gateway API permet des transformations de requêtes :

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /api/v1
    filters:
      # Réécriture du path : /api/v1/users → /users
      - type: URLRewrite
        urlRewrite:
          path:
            type: ReplacePrefixMatch
            replacePrefixMatch: /
      # Ajout d'un header
      - type: RequestHeaderModifier
        requestHeaderModifier:
          add:
            - name: X-Forwarded-By
              value: gateway
    backendRefs:
      - name: api
        port: 8080
```

---

## Fil rouge — Appliquer tout le module 09

```bash
# 1. Appliquer les manifests
kubectl apply -f 09-gateway-api/manifests/

# 2. Labelliser les namespaces
kubectl label namespace api gateway-accessible=true
kubectl label namespace frontend gateway-accessible=true

# 3. Configurer /etc/hosts
echo "127.0.0.1 app.local api.local" | sudo tee -a /etc/hosts

# 4. Port-forward sur la Gateway
kubectl port-forward -n frontend svc/cilium-gateway-main-gateway 80:80 &

# 5. Tester
curl http://api.local/users
# → ouvrir http://app.local dans le navigateur
```

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **GatewayClass** | Identifie le contrôleur qui implémente les Gateways |
| **Gateway** | Point d'entrée réseau (IP, ports, protocoles) |
| **HTTPRoute** | Règles de routage HTTP attachées à une Gateway |
| **parentRefs** | Référence à la Gateway à laquelle la route s'attache |
| **allowedRoutes** | Contrôle quels namespaces peuvent attacher des routes |
| **Strategic Merge Patch** | Met à jour partiellement une ressource existante |

---

## Aller plus loin

- TLS termination : `listeners` avec `protocol: HTTPS` et un Secret TLS
- `ReferenceGrant` : autoriser explicitement une HTTPRoute cross-namespace
- `BackendLBPolicy` : configuration du load balancing par backend
- `GRPCRoute` : routage gRPC natif

---

**← Précédent** [Module 08 — RBAC](../08-rbac/README.md)  
**Suivant →** [Module 10 — Observabilité](../10-observability/README.md)
