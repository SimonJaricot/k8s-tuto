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

> On utilisera `CiliumNetworkPolicy` pour profiter du filtrage L7.

---

## Le modèle Cilium : default-deny implicite

Contrairement à la NetworkPolicy standard Kubernetes, **Cilium n'a pas besoin d'une règle "deny-all" explicite**.

Le comportement est le suivant :
- **Aucune policy** sur un endpoint → tout le trafic est autorisé (comportement par défaut K8s)
- **Au moins une policy** sélectionne un endpoint → Cilium passe en **default-deny** pour cet endpoint : seul le trafic explicitement autorisé par une policy `Allow` passe

> C'est le modèle dit *"deny by default once selected"* : il suffit d'appliquer une policy `allow-from-api` sur le namespace `database` pour que l'endpoint postgres soit automatiquement en default-deny. Tout le trafic non explicitement autorisé est bloqué — sans avoir besoin d'écrire une policy `deny-all`.

**Testé et confirmé** :
- Après application de `allow-from-api` sur `ns/database` :
  - `app=api` depuis `ns/api` → `open` (autorisé)
  - `app=frontend` depuis `ns/frontend` → `timed out` (bloqué implicitement)

> **Piège à éviter** : `ingress: []` ou `egress: []` (listes vides) est invalide dans Cilium — la policy passe `VALID: False` et est ignorée silencieusement. Le trafic continue à passer. Ne pas utiliser de listes vides pour exprimer un deny.

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
TIMESTAMP   SOURCE                       DESTINATION                  TYPE          VERDICT    SUMMARY
...         frontend/test                database/postgres-0:5432     to-endpoint   FORWARDED  TCP Flags: SYN
```

> Le flux est **FORWARDED** : sans policy, tout passe.

---

## Stratégie : appliquer les policies dans l'ordre

### Étape 1 — Protéger le namespace database

On applique uniquement la règle `allow-from-api` : dès qu'elle sélectionne l'endpoint `postgres`, Cilium passe automatiquement en default-deny pour cet endpoint.

**Autoriser l'egress DNS** (sans cela, postgres ne peut pas résoudre de noms — nécessaire même pour les StatefulSets) :

```yaml
# manifests/01-database-allow-dns.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: database
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

**Autoriser uniquement l'API → PostgreSQL** :

```yaml
# manifests/02-database-allow-from-api.yaml
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
            k8s:io.kubernetes.pod.namespace: api   # Sélecteur de namespace Cilium
            app: api
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

> La clé `k8s:io.kubernetes.pod.namespace` est la façon Cilium de sélectionner un namespace dans un `fromEndpoints`. C'est différent du `namespaceSelector` standard Kubernetes.

```bash
kubectl apply -f 07-network-policies/manifests/01-database-allow-dns.yaml
kubectl apply -f 07-network-policies/manifests/02-database-allow-from-api.yaml

# Vérifier que les policies sont valides
kubectl get ciliumnetworkpolicy -n database
```

```
NAME              AGE   VALID
allow-dns-egress  10s   True
allow-from-api    10s   True
```

Tester depuis un Pod de debug dans `ns/api` :
```bash
# Doit réussir : app=api depuis ns/api est autorisé
kubectl run debug --image=busybox --labels="app=api" -n api --rm -it --restart=Never -- \
  nc -zv postgres.database.svc.cluster.local 5432
# → postgres.database.svc.cluster.local (10.x.x.x:5432) open
```

> **Pourquoi `--labels="app=api"` ?** Par défaut, `kubectl run debug` crée un Pod avec le label `run=debug`. La policy `allow-from-api` filtre sur `app=api` — sans ce label, le Pod de debug ne matche pas la policy et le trafic serait bloqué, faussant le test.

Tester depuis un Pod de debug dans `ns/frontend` :
```bash
# Doit échouer : frontend n'est pas dans la policy allow-from-api
kubectl run attack --image=busybox -n frontend --rm -it --restart=Never -- \
  nc -zv postgres.database.svc.cluster.local 5432
# → nc: postgres.database.svc.cluster.local: Connection timed out
```

Hubble affiche :
```
frontend/attack → database/postgres-0:5432   policy-verdict:all  INGRESS DENIED   DROPPED (TCP Flags: SYN)
```

> Sans aucune policy "deny-all" explicite, le trafic `frontend → postgres` est bloqué automatiquement. C'est le default-deny implicite de Cilium.

---

### Étape 2 — Protéger le namespace api

Même logique : dès qu'une policy sélectionne les Pods `api`, Cilium passe en default-deny pour eux.

**Autoriser l'egress DNS** :

```yaml
# manifests/03-api-allow-dns.yaml
```

**Autoriser l'egress api → postgres** :

```yaml
# manifests/04-api-allow-egress-db.yaml
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

**Autoriser l'ingress frontend → api (HTTP L7)** :

Avec Cilium, on peut filtrer au niveau HTTP (L7) — par méthode, path, headers :

```yaml
# manifests/05-api-allow-from-frontend.yaml
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

```bash
kubectl apply -f 07-network-policies/manifests/03-api-allow-dns.yaml
kubectl apply -f 07-network-policies/manifests/04-api-allow-egress-db.yaml
kubectl apply -f 07-network-policies/manifests/05-api-allow-from-frontend.yaml
```

---

### Étape 3 — Protéger le namespace frontend

```yaml
# manifests/06-frontend-policies.yaml
```

Ce fichier contient deux policies :
- `allow-dns-egress` : autorise l'egress DNS depuis `ns/frontend`
- `allow-egress-to-api` : autorise `frontend → api:8080`

```bash
kubectl apply -f 07-network-policies/manifests/06-frontend-policies.yaml
```

---

## Fil rouge — Appliquer toutes les policies en une commande

```bash
kubectl apply -f 07-network-policies/manifests/
```

Vérifier que toutes les policies sont valides :
```bash
kubectl get ciliumnetworkpolicy -A
```

```
NAMESPACE   NAME                    AGE   VALID
api         allow-dns-egress        30s   True
api         allow-egress-to-database 30s  True
api         allow-from-frontend     30s   True
database    allow-dns-egress        30s   True
database    allow-from-api          30s   True
frontend    allow-dns-egress        30s   True
frontend    allow-egress-to-api     30s   True
```

---

## Vérifier avec Hubble

Flux autorisés :
```bash
hubble observe --follow --verdict FORWARDED
```

Flux bloqués :
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

## Récapitulatif des flux autorisés

```
ns/frontend                ns/api                 ns/database
┌──────────┐   GET/POST    ┌──────────┐   TCP     ┌───────────┐
│ frontend │ ─────────────▶│   api    │ ──────────▶│ postgres  │
└──────────┘  :8080        └──────────┘  :5432     └───────────┘
     │  DNS                      │  DNS
     ▼                           ▼
  kube-dns:53               kube-dns:53

frontend → postgres  ✗ bloqué (default-deny implicite Cilium)
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
| Default-deny implicite | Oui (dès qu'une policy sélectionne un pod) | Oui (même modèle) |
| Sélecteur de namespace dans `fromEndpoints` | Via `namespaceSelector` | Via label `k8s:io.kubernetes.pod.namespace` |
| FQDN egress | Non | Oui (`toFQDNs`) |

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **CiliumNetworkPolicy** | Extension Cilium avec filtrage L7 |
| **endpointSelector** | Sélectionne les Pods auxquels la policy s'applique |
| **fromEndpoints / toEndpoints** | Sélectionne les Pods source/destination |
| **default-deny implicite** | Dès qu'une policy sélectionne un endpoint, tout le trafic non explicitement autorisé est bloqué |
| **Filtrage L7** | Filtrage HTTP par méthode/path, DNS par pattern |
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
