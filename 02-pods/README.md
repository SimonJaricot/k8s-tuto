# Module 02 — Pods

**Objectif** : comprendre la brique de base de Kubernetes, créer et inspecter des Pods, et lancer le premier conteneur PostgreSQL du fil rouge.

---

## Qu'est-ce qu'un Pod ?

Un **Pod** est la plus petite unité déployable dans Kubernetes. Il encapsule :
- Un ou plusieurs **conteneurs** (partageant le même réseau et les mêmes volumes)
- Une **adresse IP** unique dans le cluster
- Des **ressources partagées** (volumes, variables d'environnement)

```
Pod: postgres
├── container: postgres   (port 5432)
└── shared volume: /var/lib/postgresql/data
```

> En pratique, un Pod contient généralement **un seul conteneur applicatif**. Le cas multi-conteneurs (sidecar, init container) est abordé plus bas.

---

## Anatomie d'un manifest Pod

```yaml
apiVersion: v1          # Version de l'API Kubernetes
kind: Pod               # Type de ressource
metadata:
  name: postgres        # Nom unique dans le namespace
  namespace: database   # Namespace cible
  labels:               # Étiquettes libres (clé/valeur)
    app: postgres
    tier: database
  annotations:          # Métadonnées non-sélectables, informatives
    description: "Pod PostgreSQL de test"
spec:
  containers:
    - name: postgres             # Nom du conteneur dans le Pod
      image: postgres:16-alpine  # Image Docker
      ports:
        - containerPort: 5432    # Port exposé par le conteneur (informatif)
      env:
        - name: POSTGRES_DB
          value: "usersdb"
        - name: POSTGRES_USER
          value: "admin"
        - name: POSTGRES_PASSWORD
          value: "changeme"      # ← en clair pour l'instant, corrigé au module 04
```

---

## Fil rouge — Premier Pod PostgreSQL

Applique le manifest :

```bash
kubectl apply -f 02-pods/manifests/postgres-pod.yaml
```

Vérifie que le Pod démarre :

```bash
kubectl get pod -n database
```

```
NAME       READY   STATUS    RESTARTS   AGE
postgres   1/1     Running   0          15s
```

Les colonnes :
| Colonne | Signification |
|---------|---------------|
| `READY` | Conteneurs prêts / total |
| `STATUS` | `Pending`, `Running`, `Succeeded`, `Failed`, `CrashLoopBackOff` |
| `RESTARTS` | Nombre de redémarrages du conteneur |

---

## Inspecter un Pod

### Détails complets

```bash
kubectl describe pod postgres -n database
```

Points importants dans la sortie :
- `Node` : sur quel nœud tourne le Pod
- `IP` : adresse IP dans le réseau des Pods
- `Containers > State` : état du conteneur
- `Events` : historique des événements (utile pour déboguer)

### Voir les logs

```bash
# Logs du conteneur
kubectl logs postgres -n database

# Suivre les logs en temps réel
kubectl logs -f postgres -n database

# Dernières 50 lignes
kubectl logs --tail=50 postgres -n database
```

### Exécuter une commande dans le conteneur

```bash
# Ouvrir un shell interactif
kubectl exec -it postgres -n database -- bash

# Exécuter psql directement
kubectl exec -it postgres -n database -- psql -U admin -d usersdb

# Depuis psql, créer la table users
CREATE TABLE users (
  id   SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL
);
INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');
INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com');
\q
```

---

## Cycle de vie d'un Pod

```
Pending ──── ContainerCreating ──── Running ──── Succeeded
                                        │
                                        └──── Failed ──── CrashLoopBackOff
```

| Phase | Description |
|-------|-------------|
| `Pending` | Accepté par le cluster, nœud pas encore assigné (ou image en cours de pull) |
| `Running` | Au moins un conteneur en cours d'exécution |
| `Succeeded` | Tous les conteneurs ont terminé avec succès (exit 0) |
| `Failed` | Au moins un conteneur a terminé avec un code d'erreur |
| `CrashLoopBackOff` | Le conteneur crashe en boucle — Kubernetes attend avant de relancer |

Pour déboguer un `CrashLoopBackOff` :

```bash
# Voir les logs du crash précédent
kubectl logs postgres -n database --previous
```

---

## Labels et sélecteurs

Les **labels** sont des paires clé/valeur arbitraires attachées aux ressources. Ils sont fondamentaux dans Kubernetes car ils permettent de **sélectionner** des groupes de ressources.

```bash
# Filtrer les Pods par label
kubectl get pods -n database -l app=postgres

# Voir tous les labels
kubectl get pods -n database --show-labels

# Ajouter un label à un Pod existant (impératif)
kubectl label pod postgres -n database env=dev

# Supprimer un label
kubectl label pod postgres -n database env-
```

---

## Annotations

Les **annotations** sont similaires aux labels mais ne servent pas aux sélecteurs. Elles stockent des métadonnées arbitraires (URL de documentation, version de déploiement, etc.) :

```yaml
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: "..."
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
```

---

## Init Containers

Un **init container** s'exécute avant les conteneurs principaux et doit terminer avec succès. Exemple typique : attendre qu'une dépendance soit disponible.

```yaml
spec:
  initContainers:
    - name: wait-for-network
      image: busybox
      command: ['sh', '-c', 'until nslookup postgres.database.svc.cluster.local; do sleep 2; done']
  containers:
    - name: api
      image: myapi:latest
```

> Ce pattern sera utilisé au module 05 pour que l'API attende que PostgreSQL soit prêt.

---

## Limites d'un Pod nu

Un Pod créé directement **n'est pas résilient** :
- Si le Pod crashe, Kubernetes **ne le redémarre pas** automatiquement
- Si le nœud disparaît, le Pod est **perdu définitivement**
- On ne peut pas facilement **scaler** (créer plusieurs réplicas)

C'est pourquoi on n'utilise presque jamais des Pods nus en production. On les encapsule dans des **Deployments** ou des **StatefulSets** — sujet du module 03.

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **Pod** | Plus petite unité déployable — encapsule un ou plusieurs conteneurs |
| **Labels** | Paires clé/valeur pour sélectionner et organiser les ressources |
| **Annotations** | Métadonnées non-sélectables |
| **Init Container** | Conteneur qui s'exécute avant les conteneurs principaux |
| **kubectl exec** | Exécute une commande dans un conteneur en cours d'exécution |
| **kubectl logs** | Accède aux logs standard (stdout/stderr) d'un conteneur |

---

## Aller plus loin

- Pods multi-conteneurs (sidecar pattern) : deux conteneurs partageant un volume
- `kubectl debug` : créer un Pod de debug éphémère attaché à un Pod existant
- `kubectl top pod` : consommation CPU/RAM (nécessite metrics-server)

---

**← Précédent** [Module 01 — Namespaces](../01-namespaces/README.md)  
**Suivant →** [Module 03 — Workloads](../03-workloads/README.md)
