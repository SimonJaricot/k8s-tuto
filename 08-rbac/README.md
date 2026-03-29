# Module 08 — RBAC

**Objectif** : comprendre le contrôle d'accès basé sur les rôles (RBAC), créer des ServiceAccounts dédiés pour chaque composant du fil rouge, et limiter leurs permissions au strict nécessaire.

---

## Qu'est-ce que le RBAC ?

**RBAC** (Role-Based Access Control) contrôle **qui** peut faire **quoi** sur **quelles ressources** dans le cluster.

```
Sujet (qui)         Rôle (quoi)              Ressources (sur quoi)
──────────          ────────────             ─────────────────────
ServiceAccount  →   Role/ClusterRole    →    Pods, Secrets, ConfigMaps…
User            →   verbs: get, list…   →    dans un Namespace ou le cluster
Group
```

---

## ServiceAccount

Un **ServiceAccount** est une identité pour les **Pods** (à ne pas confondre avec les comptes utilisateurs humains). Chaque Pod utilise un ServiceAccount pour s'authentifier auprès de l'API Kubernetes.

Par défaut, chaque namespace a un ServiceAccount `default` utilisé si aucun n'est spécifié. Ce compte a des permissions minimales, mais la bonne pratique est de créer un ServiceAccount **dédié par application**.

```yaml
# manifests/serviceaccounts.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postgres
  namespace: database
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api
  namespace: api
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend
  namespace: frontend
```

Référencer le ServiceAccount dans un Pod :

```yaml
spec:
  serviceAccountName: postgres   # Au lieu de "default"
  automountServiceAccountToken: false   # Ne pas monter le token si non nécessaire
```

> `automountServiceAccountToken: false` est recommandé pour les Pods qui n'ont pas besoin d'appeler l'API Kubernetes (cas de PostgreSQL et du frontend).

---

## Role

Un **Role** définit un ensemble de permissions dans un **namespace** (les ressources et les verbes autorisés).

```yaml
# Exemple — Role pour lire les ConfigMaps et Secrets dans le namespace api
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-config-reader
  namespace: api
rules:
  - apiGroups: [""]             # "" = core API group
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
```

### Les verbes disponibles

| Verbe | Action HTTP | Description |
|-------|-------------|-------------|
| `get` | GET | Lire une ressource spécifique |
| `list` | GET | Lister des ressources |
| `watch` | GET (streaming) | Observer les changements |
| `create` | POST | Créer une ressource |
| `update` | PUT | Remplacer une ressource |
| `patch` | PATCH | Modifier partiellement |
| `delete` | DELETE | Supprimer une ressource |
| `deletecollection` | DELETE | Supprimer une collection |

---

## ClusterRole

Un **ClusterRole** est identique à un Role mais s'applique à l'**ensemble du cluster** (toutes ressources non-namespacées incluses).

```yaml
# Exemple — ClusterRole pour lire les nodes
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-reader
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
```

---

## RoleBinding et ClusterRoleBinding

Un **RoleBinding** associe un Role (ou ClusterRole) à un sujet (ServiceAccount, User, Group).

```yaml
# manifests/api-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-config-reader-binding
  namespace: api
subjects:
  - kind: ServiceAccount
    name: api
    namespace: api
roleRef:
  kind: Role
  name: api-config-reader
  apiGroup: rbac.authorization.k8s.io
```

```
ServiceAccount api (ns: api)
         ↓ RoleBinding: api-config-reader-binding
         Role: api-config-reader (ns: api)
              ↓ permissions
         get/list/watch ConfigMaps et Secrets dans ns: api
```

---

## Fil rouge — RBAC minimal pour le principe du moindre privilège

### PostgreSQL

PostgreSQL n'a pas besoin d'accéder à l'API Kubernetes. On lui assigne un ServiceAccount sans token monté.

```yaml
spec:
  serviceAccountName: postgres
  automountServiceAccountToken: false
```

### API Go

L'API peut avoir besoin de lire sa configuration depuis des ConfigMaps (pattern courant avec des opérateurs). On lui donne un Role minimal.

### Vérifier les permissions d'un ServiceAccount

```bash
# Tester si le ServiceAccount "api" peut lire les configmaps dans ns "api"
kubectl auth can-i get configmaps \
  --as=system:serviceaccount:api:api \
  -n api
```

```
yes
```

```bash
# Tester ce qu'il ne peut PAS faire
kubectl auth can-i delete pods \
  --as=system:serviceaccount:api:api \
  -n api
```

```
no
```

### Lister tous les droits d'un ServiceAccount

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:api:api \
  -n api
```

---

## Appliquer les manifests

```bash
kubectl apply -f 08-rbac/manifests/
```

Vérifier :

```bash
kubectl get serviceaccounts -n database
kubectl get serviceaccounts -n api
kubectl get serviceaccounts -n frontend

kubectl get roles,rolebindings -n api
```

---

## Interaction avec les NetworkPolicies

Le RBAC et les NetworkPolicies sont **complémentaires** :
- **NetworkPolicies** (Cilium) : contrôlent le trafic réseau entre Pods
- **RBAC** : contrôle l'accès à l'API Kubernetes (kubectl, operators, CI/CD)

Un Pod sans droits RBAC peut quand même communiquer sur le réseau si les NetworkPolicies le permettent — et inversement.

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **ServiceAccount** | Identité d'un Pod pour l'API Kubernetes |
| **Role** | Permissions dans un namespace |
| **ClusterRole** | Permissions à l'échelle du cluster |
| **RoleBinding** | Associe un Role à un sujet |
| **ClusterRoleBinding** | Associe un ClusterRole à un sujet, à l'échelle du cluster |
| **kubectl auth can-i** | Teste les permissions d'un sujet |
| **automountServiceAccountToken** | Désactive le montage automatique du token |

---

## Aller plus loin

- `kubectl auth reconcile` : appliquer des RBAC idempotents
- Audit logs : tracer les accès à l'API (`--audit-log-path` sur kube-apiserver)
- Impersonation : `kubectl --as=system:serviceaccount:ns:name` pour tester
- Open Policy Agent (OPA) / Kyverno : politiques d'admission plus fines

---

**← Précédent** [Module 07 — NetworkPolicies & Cilium](../07-network-policies/README.md)  
**Suivant →** [Module 09 — Gateway API](../09-gateway-api/README.md)
