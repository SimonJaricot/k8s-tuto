# Module 07 — NetworkPolicies & Cilium

**Objectif** : isoler les namespaces avec des politiques réseau Cilium, observer les flux en temps réel avec Hubble, et comprendre le filtrage L3/L4/L7.

---

## Le problème par défaut

Sans NetworkPolicy, **tous les Pods du cluster peuvent communiquer avec tous les autres**, quel que soit le namespace. C'est le comportement par défaut de Kubernetes.

```
frontend → api        ✓ souhaité
api      → database   ✓ souhaité
frontend → database   ✓ par défaut... mais NON souhaité !
api      → api        ✓ par défaut... mais inutile
```

---

## Deux niveaux de policies avec Cilium

Cilium supporte deux types de ressources :

| Ressource | Niveau | Portée |
|-----------|--------|--------|
| `NetworkPolicy` (standard K8s) | L3/L4 | Namespaced |
| `CiliumNetworkPolicy` | L3/L4/L7 (HTTP, gRPC, DNS) | Namespaced |
| `CiliumClusterwideNetworkPolicy` | L3/L4/L7 | Cluster entier |

> On utilisera principalement `CiliumNetworkPolicy` pour profiter du filtrage L7.

---

## Observer avec Hubble avant d'appliquer des policies

Avant de restreindre le trafic, observons-le avec Hubble :

```bash
# Ouvrir le port-forward Hubble (si pas déjà fait)
cilium hubble port-forward &

# Observer tous les flux en temps réel
hubble observe --follow

# Filtrer par namespace
hubble observe --namespace database --follow

# Filtrer les flux entre namespaces
hubble observe --from-namespace api --to-namespace database --follow
```

Depuis un autre terminal, générer du trafic :
```bash
# Test de connexion frontend → database (devrait être bloqué une fois les policies en place)
kubectl run test --image=busybox --rm -it --restart=Never -n frontend \
  -- sh -c "nc -zv postgres.database.svc.cluster.local 5432"
```

Sans aucune NetworkPolicy, `nc` réussit :
```
postgres.database.svc.cluster.local (10.96.x.x:5432) open
pod "test" deleted
```

Hubble affiche :
```
TIMESTAMP   SOURCE                       DESTINATION                  TYPE      VERDICT  SUMMARY
...         frontend/test                database/postgres-0:5432     to-endpoint  FORWARDED  TCP Flags: SYN
```

> Le flux est **FORWARDED** : sans policy, tout passe.

---

## Stratégie : deny-all puis whitelist

La bonne pratique est d'appliquer un **deny-all** par défaut sur chaque namespace, puis d'ouvrir uniquement le trafic nécessaire.

### Étape 1 — Deny-all sur le namespace database

```yaml
# manifests/01-database-deny-all.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deny-all
  namespace: database
spec:
  endpointSelector: {}   # Sélectionne tous les endpoints du namespace
  ingressDeny:
    - fromEntities:
        - "all"          # Bloque tout le trafic entrant
  egressDeny:
    - toEntities:
        - "all"          # Bloque tout le trafic sortant
```

> **Pourquoi `ingressDeny`/`egressDeny` et pas `ingress: []`/`egress: []` ?**
> Cilium exige qu'une policy ait au moins une règle non-vide — une liste vide est invalide (`VALID: False`) et ignorée silencieusement. Les champs `ingressDeny`/`egressDeny` expriment explicitement le blocage.

```bash
kubectl apply -f 07-network-policies/manifests/01-database-deny-all.yaml

# Vérifier que la policy est valide
kubectl get ciliumnetworkpolicy deny-all -n database
```

```
NAME       AGE   VALID
deny-all   10s   True
```

Tester depuis Hubble :
```bash
hubble observe --namespace database --follow
```

Puis retester la connexion depuis le namespace `api` avec un Pod de debug :
```bash
# nc -zv teste uniquement l'établissement de la connexion TCP (pas de protocole HTTP)
# C'est le bon outil pour tester la connectivité vers PostgreSQL (port 5432)
kubectl run debug --image=busybox -n api --rm -it --restart=Never -- \
  nc -zv postgres.database.svc.cluster.local 5432
```

Avec le deny-all actif, la connexion TCP est bloquée :
```
nc: postgres.database.svc.cluster.local (10.96.x.x:5432): Connection timed out
pod "debug" deleted
pod api/debug terminated (Error)
```

Hubble affiche maintenant :
```
api/debug:xxxxx <> database/postgres-0:5432   policy-verdict:all INGRESS DENIED   DROPPED (TCP Flags: SYN)
api/debug:xxxxx <> database/postgres-0:5432   Policy denied by denylist           DROPPED (TCP Flags: SYN)
```

> **Pourquoi `nc` et pas `wget` ?** PostgreSQL parle son propre protocole binaire, pas HTTP. `wget` établit bien la connexion TCP mais échoue à parser la réponse — même sans NetworkPolicy. `nc -zv` teste uniquement la couche TCP et retourne clairement `succeeded` ou `timed out`.

---

### Étape 2 — Autoriser uniquement l'API → PostgreSQL

```yaml
# manifests/database-allow-api.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-from-api
  namespace: database
spec:
  endpointSelector:
    matchLabels:
      app: postgres
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: api   # Sélecteur de namespace
            app: api
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

```bash
kubectl apply -f 07-network-policies/manifests/database-allow-api.yaml
```

> La clé `k8s:io.kubernetes.pod.namespace` est la façon Cilium de sélectionner un namespace dans un `fromEndpoints`. C'est différent du `namespaceSelector` standard Kubernetes.

---

### Étape 3 — Deny-all sur le namespace api

```yaml
# manifests/api-deny-all.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deny-all
  namespace: api
spec:
  endpointSelector: {}
  ingress: []
  egress: []
```

### Étape 4 — Autoriser frontend → api (HTTP L7)

Avec Cilium, on peut filtrer au niveau HTTP (L7) — par méthode, path, headers :

```yaml
# manifests/api-allow-frontend.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-from-frontend
  namespace: api
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: frontend
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/users"
              - method: POST
                path: "/users"
              - method: GET
                path: "/healthz"
```

> Seuls les appels `GET /users`, `POST /users` et `GET /healthz` sont autorisés. Une requête `DELETE /users/1` serait bloquée même si le port 8080 est ouvert.

---

### Étape 5 — Autoriser l'egress DNS

Les Pods ont besoin de résoudre des noms DNS (CoreDNS tourne dans `kube-system`). Sans cette policy, même les résolutions DNS sont bloquées.

```yaml
# manifests/allow-dns-egress.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: api
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
```

---

### Étape 6 — Autoriser l'egress api → database

```yaml
# manifests/api-allow-egress-db.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-egress-to-database
  namespace: api
spec:
  endpointSelector:
    matchLabels:
      app: api
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: database
            app: postgres
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

---

## Récapitulatif des flux autorisés

```
ns/frontend                ns/api                 ns/database
┌──────────┐   GET/POST    ┌──────────┐   TCP     ┌───────────┐
│ frontend │ ─────────────▶│   api    │ ──────────▶│ postgres  │
└──────────┘  :8080        └──────────┘  :5432     └───────────┘
     │                           │
     ▼ bloqué                    ▼ DNS vers kube-system autorisé
  postgres:5432                  kube-dns:53
```

---

## Fil rouge — Appliquer toutes les policies

```bash
kubectl apply -f 07-network-policies/manifests/
```

Vérifier avec Hubble :

```bash
hubble observe --follow --verdict DROPPED
```

Tenter une connexion interdite :
```bash
kubectl run attack --image=busybox --rm -it --restart=Never -n frontend \
  -- sh -c "nc -zv postgres.database.svc.cluster.local 5432"
```

Hubble affiche :
```
frontend/attack → database/postgres-0:5432  DROPPED  Policy denied
```

---

## Hubble UI (optionnel)

```bash
cilium hubble enable --ui
cilium hubble ui
```

L'interface graphique affiche en temps réel une carte des flux réseau entre services, avec la coloration FORWARDED/DROPPED.

---

## Différence NetworkPolicy standard vs CiliumNetworkPolicy

| Fonctionnalité | NetworkPolicy K8s | CiliumNetworkPolicy |
|----------------|-------------------|---------------------|
| Filtrage L3/L4 | Oui | Oui |
| Filtrage L7 HTTP | Non | Oui |
| Filtrage L7 gRPC | Non | Oui |
| Filtrage DNS | Non | Oui |
| Sélecteur de namespace dans `fromEndpoints` | Via `namespaceSelector` | Via label `k8s:io.kubernetes.pod.namespace` |
| FQDN egress | Non | Oui (`toFQDNs`) |

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **NetworkPolicy** | Règles de filtrage réseau standard Kubernetes (L3/L4) |
| **CiliumNetworkPolicy** | Extension Cilium avec filtrage L7 |
| **endpointSelector** | Sélectionne les Pods auxquels la policy s'applique |
| **fromEndpoints / toEndpoints** | Sélectionne les Pods source/destination |
| **deny-all** | Policy vide qui bloque tout le trafic (ingress/egress) |
| **Hubble** | Observabilité réseau — visualise les flux et verdicts |

---

## Aller plus loin

- `CiliumClusterwideNetworkPolicy` : policies qui s'appliquent à tout le cluster
- `toFQDNs` : autoriser l'egress vers des domaines externes (`*.github.com`)
- Hubble UI : carte visuelle des flux inter-services
- `cilium policy get` : inspecter les policies compilées par Cilium

---

**← Précédent** [Module 06 — Stockage](../06-storage/README.md)  
**Suivant →** [Module 08 — RBAC](../08-rbac/README.md)
