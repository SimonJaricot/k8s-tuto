# Module 09 — Gateway API

**Objectif** : exposer le frontend et l'API Go à l'extérieur du cluster en utilisant la Gateway API de Kubernetes, implémentée nativement par Cilium.

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
     ├── TCPRoute    ←── routage TCP brut (pour PostgreSQL par exemple)
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

## Gateway

Une **Gateway** est le point d'entrée réseau. Elle demande une IP externe (via un Service `LoadBalancer`) et définit les ports et protocoles acceptés.

```yaml
# manifests/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: frontend    # La Gateway réside dans un namespace
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

Avec kind, l'IP assignée est une IP Docker. Pour y accéder depuis la machine hôte, on utilise `kubectl port-forward` ou on configure un mapping de port dans `kind-config.yaml`.

---

## HTTPRoute — Exposer le frontend

Une **HTTPRoute** définit les règles de routage HTTP : sur quel hostname, quel path, vers quel Service.

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
      namespace: frontend    # Référence à la Gateway
  hostnames:
    - "app.local"            # Host header attendu
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
# Labelliser les namespaces autorisés
kubectl label namespace api gateway-accessible=true
kubectl label namespace frontend gateway-accessible=true
```

---

## Tester depuis la machine hôte

Avec kind, la ClusterIP / LoadBalancer n'est pas directement accessible depuis macOS. On utilise `kubectl port-forward` :

```bash
# Port-forward la Gateway vers localhost
kubectl port-forward -n frontend svc/cilium-gateway-main-gateway 8080:80 &

# Tester le frontend
curl -H "Host: app.local" http://localhost:8080/

# Tester l'API
curl -H "Host: api.local" http://localhost:8080/users
```

### Option avancée — Mapping de port kind

Pour un accès direct sans port-forward, modifier `kind-config.yaml` avant de créer le cluster :

```yaml
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
```

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

## NetworkPolicy — Autoriser le trafic depuis la Gateway

La Gateway Cilium crée des Pods dans le namespace `kube-system` (ou `cilium-gateway`). Il faut autoriser ce trafic dans les NetworkPolicies.

```yaml
# À ajouter aux policies du module 07
# manifests/allow-gateway-ingress.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-from-gateway
  namespace: frontend
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            io.cilium.gateway: main-gateway
```

---

## Fil rouge — État final

```
Internet / machine hôte
          │
          ▼
  Gateway: main-gateway (Cilium)
  ├── Host: app.local  → HTTPRoute frontend-route → Service frontend (ns/frontend)
  └── Host: api.local  → HTTPRoute api-route       → Service api      (ns/api)
                                                              │
                                                              ▼
                                               Service postgres (ns/database)
```

```bash
# Appliquer tout le module 09
kubectl apply -f 09-gateway-api/manifests/
kubectl label namespace api gateway-accessible=true
kubectl label namespace frontend gateway-accessible=true

# Tester
kubectl port-forward -n frontend svc/cilium-gateway-main-gateway 8080:80 &
curl -H "Host: app.local" http://localhost:8080/
curl -H "Host: api.local" http://localhost:8080/users
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
| **URLRewrite** | Filtre de transformation du chemin de requête |

---

## Aller plus loin

- TLS termination : `listeners` avec `protocol: HTTPS` et un Secret TLS
- `ReferenceGrant` : autoriser explicitement une HTTPRoute cross-namespace
- `BackendLBPolicy` : configuration du load balancing par backend
- `GRPCRoute` : routage gRPC natif

---

**← Précédent** [Module 08 — RBAC](../08-rbac/README.md)  
**Suivant →** [Module 10 — Observabilité](../10-observability/README.md)
