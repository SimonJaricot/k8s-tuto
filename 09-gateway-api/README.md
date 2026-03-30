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

> **Important — ordre d'installation** : Cilium doit détecter les CRDs Gateway API au démarrage pour créer automatiquement la `GatewayClass cilium`. Si Cilium a été installé **avant** les CRDs (cas du parcours normal où `init.sh` précède ce module), il faut relancer la détection avec un `helm upgrade --reuse-values` :
>
> ```bash
> helm upgrade cilium cilium/cilium \
>   --version 1.19.2 \
>   --namespace kube-system \
>   --reuse-values
> ```
>
> Cette commande ne change aucune option — elle force juste Cilium à redémarrer et à créer la GatewayClass maintenant que les CRDs sont présents.
>
> Si tu utilises `init.sh` fourni dans ce repo, cette étape est inutile : les CRDs sont déjà installés avant Cilium.

### Options Cilium requises (déjà dans `init.sh`)

```bash
helm install cilium cilium/cilium \
  --set gatewayAPI.enabled=true \
  --set kubeProxyReplacement=true \
  --set l2announcements.enabled=true \
  # ...
```

> `kubeProxyReplacement=true` est **obligatoire** pour la Gateway API. Sans ce flag, la GatewayClass reste en `Accepted: Unknown`.  
> `l2announcements.enabled=true` est requis pour que Cilium annonce l'IP LoadBalancer sur le réseau L2.

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
Navigateur (Mac)
    │
    │  http://app.local:8080  (résolu vers 127.0.0.1 via /etc/hosts)
    │  http://api.local:8080  (résolu vers 127.0.0.1 via /etc/hosts)
    │
    ▼
localhost:8080  ──[extraPortMappings]──▶  NodePort 30080 (kind-control-plane)
                                                │
                                                ▼ (Cilium eBPF)
                                         Gateway main-gateway (172.18.0.200:80)
                                                │
                                    ┌───────────┴───────────┐
                                    ▼                       ▼
                             frontend:80             api:8080
                           (ns/frontend)            (ns/api)
                                                        │
                                                        ▼
                                                postgres:5432
                                               (ns/database)
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
kubectl apply -f 09-gateway-api/manifests/

# Attendre que la Gateway obtienne une IP
kubectl get gateway main-gateway -n frontend -w
```

```
NAME           CLASS    ADDRESS        PROGRAMMED   AGE
main-gateway   cilium   172.18.0.200   True         15s
```

> Cilium crée automatiquement un Service `cilium-gateway-main-gateway` de type `LoadBalancer` dans `ns/frontend`. L'adresse IP est allouée par le `CiliumLoadBalancerIPPool` (manifests/lb-ip-pool.yaml).

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

Jusqu'ici, le frontend utilisait `http://api.api.svc.cluster.local:8080` comme `API_URL` — une URL interne au cluster, non résolvable par un navigateur. Maintenant que la Gateway expose l'API sous `http://api.local:8080`, on met à jour le Deployment :

```bash
kubectl patch deployment frontend -n frontend --type=strategic \
  --patch-file 09-gateway-api/frontend-api-url-patch.yaml
```

Le fichier `frontend-api-url-patch.yaml` est un **strategic merge patch** — il met à jour uniquement la variable `API_URL` sans toucher au reste du Deployment :

```yaml
# frontend-api-url-patch.yaml  (hors du dossier manifests/)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: frontend
spec:
  template:
    spec:
      containers:
        - name: frontend
          env:
            - name: API_URL
              value: "http://api.local:8080"
```

> Ce fichier est placé à la racine de `09-gateway-api/` et non dans `manifests/` pour ne pas être inclus accidentellement dans un `kubectl apply -f manifests/` (un Deployment incomplet échoue à la validation).

Le Pod frontend redémarre automatiquement avec la nouvelle valeur.

---

## NetworkPolicies — Autoriser le trafic depuis la Gateway

Cilium Gateway utilise un proxy Envoy interne avec une identité réservée (`reserved:ingress`). On utilise `fromEntities: ["ingress"]` pour autoriser ce trafic, car l'identité Envoy n'est pas un pod ordinaire.

```bash
kubectl apply -f 09-gateway-api/manifests/gateway-network-policies.yaml
```

Vérifier que les nouvelles policies sont valides :

```bash
kubectl get ciliumnetworkpolicy -A
```

Les policies `allow-from-gateway` dans `ns/frontend` et `ns/api` apparaissent avec `VALID: True`.

> **Piège courant** : utiliser `fromEndpoints` avec `io.cilium/gateway: main-gateway` ne fonctionne pas — ce label ne correspond pas à l'identité réelle du proxy Envoy. Le trafic serait alors bloqué (503 depuis la Gateway).

---

## Tester depuis la machine hôte

### Prérequis : `kind-config.yaml` avec extraPortMappings

Le fichier `kind-config.yaml` à la racine du repo expose le port NodePort `30080` du nœud control-plane sur le port `8080` de la machine hôte. Ce mapping est défini une fois à la création du cluster (c'est pourquoi il est dans `kind-config.yaml` et non dans les manifests Kubernetes).

### Étape 1 — Fixer le NodePort de la Gateway à 30080

Cilium crée le Service `cilium-gateway-main-gateway` avec un NodePort aléatoire. Il faut le fixer à `30080` pour correspondre au mapping kind :

```bash
kubectl patch svc cilium-gateway-main-gateway -n frontend \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080}]'
```

Vérifier :

```bash
kubectl get svc -n frontend cilium-gateway-main-gateway
```

```
NAME                          TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)        AGE
cilium-gateway-main-gateway   LoadBalancer   10.96.45.95   172.18.0.200   80:30080/TCP   5m
```

### Étape 2 — Configurer /etc/hosts

```bash
echo "127.0.0.1 app.local api.local" | sudo tee -a /etc/hosts
```

> Pour nettoyer après le tutoriel : supprimer la ligne ajoutée dans `/etc/hosts`.

### Étape 3 — Tester l'API

```bash
curl http://api.local:8080/users
```

```json
[{"id":1,"name":"Charlie","email":"charlie@example.com"}]
```

```bash
curl http://api.local:8080/healthz
```

```json
{"status":"ok"}
```

### Étape 4 — Tester le frontend dans le navigateur

Ouvrir `http://app.local:8080` dans le navigateur. La liste des utilisateurs s'affiche, le formulaire de création fonctionne.

> **Pourquoi ça marche maintenant ?**  
> Le browser envoie `GET /users` vers `http://api.local:8080` — résolu par `/etc/hosts` vers `127.0.0.1:8080`, redirigé par `extraPortMappings` vers NodePort `30080` sur le nœud kind, puis routé par Cilium eBPF vers la Gateway Envoy, puis par la HTTPRoute `api-route` vers le Service `api`.

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
# 1. Appliquer les manifests (Gateway, HTTPRoutes, NetworkPolicies, LB IP Pool)
kubectl apply -f 09-gateway-api/manifests/

# 2. Labelliser les namespaces pour autoriser l'attachement des HTTPRoutes
kubectl label namespace api gateway-accessible=true
kubectl label namespace frontend gateway-accessible=true

# 3. Attendre que la Gateway soit programmée avec une IP
kubectl get gateway main-gateway -n frontend -w
# → PROGRAMMED: True, ADDRESS: 172.18.0.200

# 4. Fixer le NodePort à 30080 (pour correspondre à extraPortMappings dans kind-config.yaml)
kubectl patch svc cilium-gateway-main-gateway -n frontend \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080}]'

# 5. Patcher l'API_URL du frontend
kubectl patch deployment frontend -n frontend --type=strategic \
  --patch-file 09-gateway-api/frontend-api-url-patch.yaml

# 6. Configurer /etc/hosts
echo "127.0.0.1 app.local api.local" | sudo tee -a /etc/hosts

# 7. Tester
curl http://api.local:8080/healthz
# → {"status":"ok"}

curl http://api.local:8080/users
# → [{"id":1,...}]

# 8. Ouvrir dans le navigateur
open http://app.local:8080
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
| **CiliumLoadBalancerIPPool** | Alloue des IPs pour les Services LoadBalancer |
| **CiliumL2AnnouncementPolicy** | Annonce les IPs LoadBalancer sur le réseau L2 (ARP) |
| **reserved:ingress** | Identité Cilium du proxy Envoy de la Gateway |
| **Strategic Merge Patch** | Met à jour partiellement une ressource existante |
| **extraPortMappings** | Expose un NodePort kind sur la machine hôte |

---

## Aller plus loin

- TLS termination : `listeners` avec `protocol: HTTPS` et un Secret TLS
- `ReferenceGrant` : autoriser explicitement une HTTPRoute cross-namespace
- `BackendLBPolicy` : configuration du load balancing par backend
- `GRPCRoute` : routage gRPC natif

---

**← Précédent** [Module 08 — RBAC](../08-rbac/README.md)  
**Suivant →** [Module 10 — Observabilité](../10-observability/README.md)
