# Module 01 — Namespaces

**Objectif** : comprendre ce qu'est un namespace, pourquoi en avoir plusieurs, et créer les trois namespaces du fil rouge.

---

## Qu'est-ce qu'un Namespace ?

Un **Namespace** est une partition logique à l'intérieur d'un cluster Kubernetes. Il permet de :

- **Isoler** des ressources (les Pods d'un namespace ne voient pas directement ceux d'un autre)
- **Délimiter des périmètres de sécurité** (RBAC, NetworkPolicies par namespace)
- **Organiser** des environnements (prod, staging, dev) ou des équipes dans un même cluster

```
Cluster
├── namespace: kube-system    ← composants Kubernetes internes
├── namespace: default        ← namespace par défaut
├── namespace: database       ← notre PostgreSQL
├── namespace: api            ← notre API Go
└── namespace: frontend       ← notre interface web
```

> **Note** : en production, regrouper l'API et le frontend dans un seul namespace est souvent suffisant. Ici, on les sépare volontairement pour explorer les NetworkPolicies entre namespaces au module 07.

---

## Namespaces système

Avant de créer les nôtres, explorons les namespaces déjà présents :

```bash
kubectl get namespaces
```

```
NAME              STATUS   AGE
default           Active   5m
kube-node-lease   Active   5m
kube-public       Active   5m
kube-system       Active   5m
```

| Namespace | Rôle |
|-----------|------|
| `default` | Namespace utilisé si aucun n'est précisé |
| `kube-system` | Composants internes (scheduler, etcd, Cilium…) |
| `kube-public` | Ressources lisibles par tous, même sans authentification |
| `kube-node-lease` | Objets `Lease` pour le heartbeat des nœuds |

---

## Créer un Namespace

### En ligne de commande (impératif)

```bash
kubectl create namespace database
```

Cette commande est rapide mais elle ne laisse aucune trace dans le repo. On préfère l'approche déclarative.

### Avec un manifest YAML (déclaratif)

```yaml
# manifests/namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: database
  labels:
    app.kubernetes.io/part-of: k8s-tuto
    module: "01"
```

Les **labels** permettront plus tard de sélectionner des namespaces dans les NetworkPolicies Cilium.

```bash
kubectl apply -f manifests/namespaces.yaml
```

---

## Fil rouge — Créer les 3 namespaces

Le manifest [`manifests/namespaces.yaml`](./manifests/namespaces.yaml) crée les trois namespaces du fil rouge :

```bash
kubectl apply -f 01-namespaces/manifests/namespaces.yaml
```

Vérifie :

```bash
kubectl get namespaces -l app.kubernetes.io/part-of=k8s-tuto
```

```
NAME       STATUS   AGE
api        Active   3s
database   Active   3s
frontend   Active   3s
```

---

## Travailler avec les namespaces

### Filtrer les ressources par namespace

```bash
# Lister les Pods d'un namespace spécifique
kubectl get pods -n database

# Lister les ressources de tous les namespaces
kubectl get pods --all-namespaces
# ou
kubectl get pods -A
```

### Changer le namespace par défaut de son contexte

Taper `-n database` à chaque commande devient vite fastidieux. On peut changer le namespace actif :

```bash
# Définir le namespace par défaut du contexte courant
kubectl config set-context --current --namespace=database

# Vérifier
kubectl config view --minify | grep namespace

# Revenir à default
kubectl config set-context --current --namespace=default
```

> **Outil recommandé** : [kubens](https://github.com/ahmetb/kubectx) (`brew install kubectx`) — change de namespace avec `kubens database`.

### Décrire un namespace

```bash
kubectl describe namespace database
```

```
Name:         database
Labels:       app.kubernetes.io/part-of=k8s-tuto
              kubernetes.io/metadata.name=database
Annotations:  <none>
Status:       Active

No resource quota.
No LimitRange resource.
```

---

## ResourceQuota et LimitRange (aperçu)

Les namespaces permettent aussi de limiter les ressources consommées par un groupe d'applications :

```yaml
# Exemple — à ne pas appliquer maintenant
apiVersion: v1
kind: ResourceQuota
metadata:
  name: db-quota
  namespace: database
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    pods: "10"
```

> Ces concepts seront approfondis au module 10 (Observabilité et limites de ressources).

---

## Supprimer un Namespace

```bash
# Supprime le namespace ET toutes les ressources qu'il contient
kubectl delete namespace database
```

Ne pas exécuter cela maintenant — on en aura besoin pour la suite !

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **Namespace** | Partition logique du cluster |
| **kubectl apply** | Applique un manifest de manière déclarative (crée ou met à jour) |
| **Labels** | Paires clé/valeur attachées aux ressources, utilisées pour les sélecteurs |
| **Context kubectl** | Combinaison cluster + user + namespace par défaut |

---

## Aller plus loin

- `kubectx` / `kubens` : outils pour basculer rapidement entre contextes et namespaces
- Hiérarchie de namespaces : [Hierarchical Namespace Controller (HNC)](https://github.com/kubernetes-sigs/hierarchical-namespaces)
- ResourceQuota et LimitRange : contrôle des ressources par namespace

---

**← Précédent** [Module 00 — Setup](../00-setup/README.md)  
**Suivant →** [Module 02 — Pods](../02-pods/README.md)
