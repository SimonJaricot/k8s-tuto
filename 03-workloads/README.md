# Module 03 — Workloads

**Objectif** : comprendre les contrôleurs qui gèrent les Pods (Deployment, StatefulSet, DaemonSet, ReplicaSet) et déployer PostgreSQL en StatefulSet et l'API Go en Deployment.

---

## Pourquoi des contrôleurs ?

Un Pod nu (module 02) n'est pas résilient : s'il crashe ou si son nœud disparaît, il ne revient pas. Les **contrôleurs de workload** résolvent ce problème en maintenant en permanence un **état désiré** déclaré dans le manifest.

```
État désiré (manifest)     État réel (cluster)
replicas: 3          ──▶   Pod-1 Running
                           Pod-2 Running
                           Pod-3 ← crashé → Controller recrée Pod-3
```

---

## ReplicaSet

Un **ReplicaSet** garantit qu'un nombre précis de réplicas d'un Pod tourne à tout moment. Il est rarement utilisé directement — on passe par les Deployments qui le gèrent automatiquement.

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: api-rs
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api        # Sélectionne les Pods portant ce label
  template:           # Template des Pods à créer
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:alpine
```

---

## Deployment

Un **Deployment** encapsule un ReplicaSet et ajoute la gestion des **mises à jour** (rolling update, rollback). C'est la ressource standard pour les applications sans état (stateless).

```
Deployment
└── ReplicaSet (v1)
    ├── Pod-1
    ├── Pod-2
    └── Pod-3
```

Lors d'une mise à jour d'image :

```
Deployment
├── ReplicaSet (v1) — 3 → 2 → 1 → 0 pods  (ancien)
└── ReplicaSet (v2) — 0 → 1 → 2 → 3 pods  (nouveau)
```

### Fil rouge — Deployment de l'API Go

```bash
kubectl apply -f 03-workloads/manifests/api-deployment.yaml
```

```bash
kubectl get deployment -n api
```

```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
api    0/2     2            0           30s
```

Les Pods ne sont pas prêts. C'est l'occasion d'utiliser les outils de diagnostic.

### Diagnostiquer avec describe et logs

```bash
kubectl get pods -n api
```

```
NAME                   READY   STATUS             RESTARTS   AGE
api-6d69cf69cc-wkpxt   0/1     CrashLoopBackOff   3          2m
api-6d69cf69cc-b9k2p   0/1     CrashLoopBackOff   3          2m
```

```bash
# Inspecter un Pod pour lire les Events
kubectl describe pod <nom-du-pod> -n api
```

La section `Events` indique :

```
Warning  BackOff    kubelet  Back-off restarting failed container api
```

```bash
# Lire les logs du crash précédent
kubectl logs <nom-du-pod> -n api --previous
```

```
Failed to create table: dial tcp: lookup postgres.database.svc.cluster.local on 10.96.0.10:53: no such host
```

L'API tente de résoudre `postgres.database.svc.cluster.local` au démarrage et échoue — ce nom DNS n'existe pas encore car le **Service** PostgreSQL n'a pas encore été créé.

### Confirmer depuis l'intérieur du Pod

Même si le Pod crashe rapidement, on peut lancer un Pod de debug temporaire pour tester la résolution DNS :

```bash
# Lancer un Pod de debug dans le namespace api
kubectl run debug --image=busybox -n api --rm -it --restart=Never -- sh
```

Depuis ce shell :

```sh
# Tenter la résolution DNS du Service PostgreSQL
nslookup postgres.database.svc.cluster.local
```

```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

nslookup: can't resolve 'postgres.database.svc.cluster.local'
```

Le DNS Kubernetes (`10.96.0.10`) répond mais ne connaît pas `postgres.database.svc.cluster.local` — aucun Service de ce nom n'existe dans le namespace `database`.

> **Ce `CrashLoopBackOff` se résoudra au module 05** quand le Service PostgreSQL sera créé. Le DNS interne Kubernetes crée automatiquement une entrée `<service>.<namespace>.svc.cluster.local` pour chaque Service.

> **Concept illustré** : Kubernetes redémarre automatiquement un conteneur qui crashe (`restartPolicy: Always` par défaut), avec un délai exponentiel entre chaque tentative — c'est le `BackOff` de `CrashLoopBackOff`.

### Déboguer un ImagePullBackOff

Si les Pods restent en `Pending` ou `0/2 Ready`, commence par inspecter l'état des Pods :

```bash
kubectl get pods -n api
```

```
NAME                   READY   STATUS             RESTARTS   AGE
api-57dc96666-9t8vb    0/1     ImagePullBackOff   0          30s
```

Inspecte le Pod en erreur pour lire le message exact :

```bash
kubectl describe pod <nom-du-pod> -n api
```

Les causes les plus fréquentes dans la section `Events` :

| Message dans Events | Cause | Solution |
|---------------------|-------|----------|
| `repository does not exist` | Image ou tag inexistant sur le registry | Vérifier le nom et le tag dans le manifest |
| `no match for platform in manifest` | Image non disponible pour l'architecture du nœud (ex. arm64 sur Apple Silicon) | Rebuilder l'image en multi-arch (`linux/amd64,linux/arm64`) |
| `unauthorized` | Registry privé sans credentials | Ajouter un `imagePullSecret` |
| `ErrImagePull` / `ImagePullBackOff` | Kubernetes abandonne après plusieurs échecs | Corriger la cause puis re-`apply` le manifest |

Pour corriger le tag dans le manifest et réappliquer :

```bash
# Éditer le manifest (changer le tag image)
# Puis réappliquer — Kubernetes détecte le changement et redémarre les Pods
kubectl apply -f 03-workloads/manifests/api-deployment.yaml
```

> **Note** : `kubectl rollout restart` redémarre les Pods avec la **même image** — il ne résout pas un `ImagePullBackOff`. La seule solution est de corriger l'image référencée.

### Opérations de base sur un Deployment

```bash
# Scaler à 3 réplicas
kubectl scale deployment api -n api --replicas=3

# Voir le rollout en temps réel
kubectl rollout status deployment/api -n api

# Historique des versions
kubectl rollout history deployment/api -n api

# Rollback à la version précédente
kubectl rollout undo deployment/api -n api

# Mettre à jour l'image (déclenche un rolling update)
kubectl set image deployment/api api=myapi:v2 -n api
```

### Stratégies de déploiement

```yaml
spec:
  strategy:
    type: RollingUpdate       # Par défaut
    rollingUpdate:
      maxSurge: 1             # Pods en plus pendant la mise à jour
      maxUnavailable: 0       # Pods indisponibles max pendant la mise à jour
```

| Stratégie | Description |
|-----------|-------------|
| `RollingUpdate` | Remplace les Pods progressivement — zéro downtime |
| `Recreate` | Supprime tous les anciens Pods avant d'en créer de nouveaux — downtime |

---

## StatefulSet

Un **StatefulSet** est conçu pour les applications **avec état** (bases de données, queues). Il garantit :

- Des **noms de Pods stables** : `postgres-0`, `postgres-1`…
- Un **ordre de démarrage/arrêt** prévisible
- Des **volumes persistants individuels** par Pod (chaque réplica a son propre stockage)

```
StatefulSet: postgres
├── postgres-0  ←→  PVC: data-postgres-0
├── postgres-1  ←→  PVC: data-postgres-1
└── postgres-2  ←→  PVC: data-postgres-2
```

> Contrairement à un Deployment où tous les Pods partagent les mêmes volumes, chaque Pod d'un StatefulSet a **ses propres** volumes persistants. Essentiel pour une base de données.

### Fil rouge — StatefulSet PostgreSQL

```bash
# Supprimer le Pod nu du module 02
kubectl delete pod postgres -n database

# Déployer le StatefulSet
kubectl apply -f 03-workloads/manifests/postgres-statefulset.yaml
```

```bash
kubectl get statefulset -n database
```

```
NAME       READY   AGE
postgres   1/1     20s
```

```bash
kubectl get pods -n database
```

```
NAME         READY   STATUS    RESTARTS   AGE
postgres-0   1/1     Running   0          20s
```

> Notez le suffixe `-0` : c'est l'index ordinal du Pod dans le StatefulSet.

---

## DaemonSet

Un **DaemonSet** garantit qu'un Pod tourne sur **chaque nœud** du cluster (ou un sous-ensemble). Cilium lui-même est déployé en DaemonSet.

```
Nœud kind-worker        → cilium-xxxxx   (DaemonSet)
Nœud kind-worker2       → cilium-yyyyy   (DaemonSet)
Nœud kind-control-plane → cilium-zzzzz   (DaemonSet)
```

```bash
# Observer le DaemonSet Cilium
kubectl get daemonset cilium -n kube-system
```

Cas d'usage : agents de monitoring, collecteurs de logs, proxies réseau.

---

## Job et CronJob (aperçu)

| Ressource | Description |
|-----------|-------------|
| **Job** | Lance un ou plusieurs Pods jusqu'à complétion (ex: migration de BDD) |
| **CronJob** | Planifie un Job selon une expression cron |

```yaml
# Exemple Job — migration de base de données
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  namespace: database
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: myapi:latest
          command: ["./migrate", "--up"]
```

---

## Récapitulatif des contrôleurs

| Ressource | Usage | État | Pods stables |
|-----------|-------|------|--------------|
| **Deployment** | Apps stateless (API, frontend) | Sans état | Non |
| **StatefulSet** | Apps stateful (BDD, queues) | Avec état | Oui (`app-0`, `app-1`) |
| **DaemonSet** | Agents système (CNI, monitoring) | — | Un par nœud |
| **Job** | Tâches ponctuelles | — | Non |
| **CronJob** | Tâches planifiées | — | Non |

---

## État du fil rouge à ce stade

```
ns/database:  StatefulSet postgres-0       ✓ Running
ns/api:       Deployment api (2 réplicas)  ✗ CrashLoopBackOff — Service postgres manquant
ns/frontend:  (pas encore déployé)
```

> L'API crashe car le Service PostgreSQL n'existe pas encore — ce sera corrigé au module 05.

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **ReplicaSet** | Maintient N réplicas d'un Pod |
| **Deployment** | ReplicaSet + rolling updates + rollback |
| **StatefulSet** | Pods ordonnés, noms stables, volumes individuels |
| **DaemonSet** | Un Pod par nœud |
| **Rolling Update** | Mise à jour sans interruption de service |

---

## Aller plus loin

- `kubectl rollout pause/resume` : mettre en pause un déploiement en cours
- Stratégie Blue/Green avec deux Deployments et un Service
- Canary deployments avec des labels et des poids de trafic

---

**← Précédent** [Module 02 — Pods](../02-pods/README.md)  
**Suivant →** [Module 04 — Configuration](../04-configuration/README.md)
