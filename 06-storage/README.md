# Module 06 — Stockage

**Objectif** : comprendre la persistance des données dans Kubernetes avec les PersistentVolumes, PersistentVolumeClaims et StorageClasses, et garantir que les données PostgreSQL survivent aux redémarrages de Pods.

---

## Le problème de la persistance

Par défaut, le système de fichiers d'un conteneur est **éphémère** : toutes les données écrites sont perdues dès que le Pod est supprimé ou redémarré.

```
postgres-0 crashe → recréé → /var/lib/postgresql/data = vide ← problème
```

Pour persister les données, Kubernetes utilise des **Volumes** qui survivent au cycle de vie des Pods.

---

## Les trois abstractions

```
StorageClass  ←── définit "comment" créer du stockage (provider, type)
     │
     ▼
PersistentVolume (PV)  ←── un morceau de stockage réel dans le cluster
     │
     ▼
PersistentVolumeClaim (PVC)  ←── la demande d'un Pod pour du stockage
     │
     ▼
Pod (volumeMount)  ←── monte le PVC comme un répertoire
```

---

## StorageClass

Une **StorageClass** décrit un type de stockage disponible dans le cluster et comment le provisionner dynamiquement.

```bash
# Voir les StorageClasses disponibles
kubectl get storageclass
```

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

Avec kind, la StorageClass `standard` utilise `local-path-provisioner` : elle crée des répertoires sur le nœud. Simple pour le dev, pas adapté à la production.

```yaml
# Référence dans un PVC
storageClassName: standard
```

---

## PersistentVolume (PV)

Un **PV** est un morceau de stockage provisionné dans le cluster, soit manuellement (statique), soit automatiquement par une StorageClass (dynamique).

```yaml
# Exemple de PV statique (rarement utilisé directement)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /data/postgres    # Chemin sur le nœud (uniquement pour le dev)
```

---

## PersistentVolumeClaim (PVC)

Un **PVC** est une **demande de stockage** faite par un Pod. Kubernetes associe automatiquement le PVC à un PV compatible (ou en provisionne un via la StorageClass).

```yaml
# manifests/postgres-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: database
spec:
  accessModes:
    - ReadWriteOnce    # Un seul nœud en lecture/écriture
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
```

### Modes d'accès

| Mode | Abréviation | Description |
|------|-------------|-------------|
| `ReadWriteOnce` | RWO | Montable en lecture/écriture par un seul nœud |
| `ReadOnlyMany` | ROX | Montable en lecture seule par plusieurs nœuds |
| `ReadWriteMany` | RWX | Montable en lecture/écriture par plusieurs nœuds |
| `ReadWriteOncePod` | RWOP | Montable par un seul Pod (Kubernetes 1.22+) |

> PostgreSQL nécessite `ReadWriteOnce` : une seule instance écrit dans les données.

---

## Monter un PVC dans un Pod

```yaml
spec:
  volumes:
    - name: postgres-storage
      persistentVolumeClaim:
        claimName: postgres-data    # Référence au PVC
  containers:
    - name: postgres
      volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
```

---

## StatefulSet et volumeClaimTemplates

Pour un StatefulSet, on ne crée pas le PVC manuellement. On utilise `volumeClaimTemplates` : Kubernetes crée **automatiquement un PVC par réplica**, nommé `<template-name>-<pod-name>`.

```yaml
# Dans le StatefulSet postgres
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: standard
      resources:
        requests:
          storage: 1Gi
```

Résultat :
```
PVC: data-postgres-0  →  Pod: postgres-0
PVC: data-postgres-1  →  Pod: postgres-1  (si replicas: 2)
```

---

## Fil rouge — Vérifier la persistance

```bash
# Appliquer le StatefulSet avec PVC
kubectl apply -f 06-storage/manifests/postgres-statefulset.yaml

# Vérifier les PVCs créés
kubectl get pvc -n database
```

```
NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES
data-postgres-0   Bound    pvc-a1b2c3d4-...                           1Gi        RWO
```

```bash
# Vérifier le PV associé
kubectl get pv
```

```
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM
pvc-a1b2c3d4-...                           1Gi        RWO            Delete           Bound    database/data-postgres-0
```

### Test de persistance

```bash
# Insérer des données
kubectl exec -it postgres-0 -n database -- psql -U admin -d usersdb \
  -c "INSERT INTO users (name, email) VALUES ('Charlie', 'charlie@example.com');"

# Supprimer et recréer le Pod (le PVC reste)
kubectl delete pod postgres-0 -n database

# Attendre que le StatefulSet recrée le Pod
kubectl wait pod/postgres-0 -n database --for=condition=Ready --timeout=60s

# Vérifier que les données sont toujours là
kubectl exec -it postgres-0 -n database -- psql -U admin -d usersdb \
  -c "SELECT * FROM users;"
```

```
 id |  name   |        email
----+---------+---------------------
  1 | Alice   | alice@example.com
  2 | Bob     | bob@example.com
  3 | Charlie | charlie@example.com
```

---

## Politique de récupération (Reclaim Policy)

Que se passe-t-il quand un PVC est supprimé ?

| Politique | Comportement |
|-----------|-------------|
| `Delete` | Le PV et les données sont supprimés (défaut sur cloud) |
| `Retain` | Le PV est conservé mais doit être libéré manuellement |
| `Recycle` | Déprécié — effaçait les données et rendait le PV disponible |

> Avec kind et `local-path-provisioner`, la politique est `Delete` : supprimer le PVC supprime les données. En production, utiliser `Retain` pour les bases de données.

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **PersistentVolume (PV)** | Morceau de stockage dans le cluster |
| **PersistentVolumeClaim (PVC)** | Demande de stockage faite par un Pod |
| **StorageClass** | Template de provisionnement dynamique de stockage |
| **volumeClaimTemplates** | PVCs automatiques par réplica dans un StatefulSet |
| **ReadWriteOnce** | Mode d'accès d'un seul nœud en écriture |
| **Reclaim Policy** | Comportement à la suppression d'un PVC |

---

## Aller plus loin

- `kubectl describe pvc data-postgres-0 -n database` : voir les événements de binding
- CSI (Container Storage Interface) : standard pour les plugins de stockage
- Snapshots de volumes : `VolumeSnapshot` pour les sauvegardes
- `kubectl cp` : copier des fichiers depuis/vers un Pod

---

**← Précédent** [Module 05 — Réseau interne](../05-networking/README.md)  
**Suivant →** [Module 07 — NetworkPolicies & Cilium](../07-network-policies/README.md)
