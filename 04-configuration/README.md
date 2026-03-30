# Module 04 — Configuration

**Objectif** : externaliser la configuration et les secrets des applications avec ConfigMap et Secret, et les injecter dans les Pods via des variables d'environnement ou des volumes.

---

## Pourquoi externaliser la configuration ?

Mettre la configuration directement dans les images Docker pose plusieurs problèmes :
- Impossible de changer l'URL de la base sans reconstruire l'image
- Les mots de passe sont visibles dans le Dockerfile et l'historique git
- Pas de différenciation dev / staging / prod

Kubernetes propose deux ressources pour séparer configuration et code :

| Ressource | Contenu | Encodage |
|-----------|---------|----------|
| **ConfigMap** | Configuration non-sensible | Texte brut |
| **Secret** | Données sensibles (mots de passe, tokens) | Base64 |

> **Important** : Base64 n'est **pas du chiffrement**. Les Secrets Kubernetes ne sont pas chiffrés par défaut dans etcd. Pour de la vraie sécurité, utiliser etcd encryption at rest ou un gestionnaire de secrets externe (Vault, AWS Secrets Manager…).

---

## ConfigMap

### Créer un ConfigMap

```yaml
# manifests/postgres-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-config
  namespace: database
data:
  POSTGRES_DB: "usersdb"
  DB_PORT: "5432"
  # Fichier de configuration complet (clé = nom du fichier)
  pg_hba.conf: |
    # TYPE  DATABASE  USER  ADDRESS   METHOD
    local   all       all             trust
    host    all       all   0.0.0.0/0 scram-sha-256
```

### Créer un ConfigMap en ligne de commande

```bash
# Depuis des valeurs littérales
kubectl create configmap postgres-config \
  --from-literal=POSTGRES_DB=usersdb \
  --from-literal=DB_PORT=5432 \
  -n database

# Depuis un fichier
kubectl create configmap nginx-config \
  --from-file=nginx.conf \
  -n frontend
```

---

## Secret

### Créer un Secret

```yaml
# manifests/postgres-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: database
type: Opaque
stringData:          # Kubernetes encode automatiquement en base64
  POSTGRES_USER: "admin"
  POSTGRES_PASSWORD: "S3cur3P@ssw0rd!"
```

> Utiliser `stringData` plutôt que `data` : plus lisible, Kubernetes gère l'encodage base64.

```bash
# En ligne de commande
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=admin \
  --from-literal=POSTGRES_PASSWORD='S3cur3P@ssw0rd!' \
  -n database
```

### Types de Secrets

| Type | Usage |
|------|-------|
| `Opaque` | Données génériques (par défaut) |
| `kubernetes.io/dockerconfigjson` | Credentials pour un registry Docker privé |
| `kubernetes.io/tls` | Certificat TLS (cert + clé) |
| `kubernetes.io/service-account-token` | Token de ServiceAccount |

---

## Injecter la configuration dans les Pods

### Méthode 1 : variables d'environnement (clé par clé)

```yaml
spec:
  containers:
    - name: postgres
      env:
        - name: POSTGRES_DB
          valueFrom:
            configMapKeyRef:
              name: postgres-config
              key: POSTGRES_DB
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: POSTGRES_PASSWORD
```

### Méthode 2 : envFrom (toutes les clés d'un coup)

```yaml
spec:
  containers:
    - name: postgres
      envFrom:
        - configMapRef:
            name: postgres-config
        - secretRef:
            name: postgres-secret
```

### Méthode 3 : volumes (montage comme fichiers)

Utile pour les fichiers de configuration (nginx.conf, pg_hba.conf…) :

```yaml
spec:
  volumes:
    - name: pg-config-vol
      configMap:
        name: postgres-config
        items:
          - key: pg_hba.conf
            path: pg_hba.conf   # Nom du fichier dans le conteneur
  containers:
    - name: postgres
      volumeMounts:
        - name: pg-config-vol
          mountPath: /etc/postgresql/
          readOnly: true
```

---

## Fil rouge — Appliquer la configuration

> **Attention — migration du mot de passe PostgreSQL** : si tu as suivi le module 02 (Pod postgres avec `POSTGRES_PASSWORD=changeme` en dur), PostgreSQL a déjà initialisé ses données avec cet ancien mot de passe. PostgreSQL ne relit **pas** `POSTGRES_PASSWORD` au redémarrage si les données existent déjà — changer le Secret ne suffit pas.
>
> Il faut supprimer le PVC pour forcer une réinitialisation complète avant d'appliquer le StatefulSet de ce module :
>
> ```bash
> kubectl delete statefulset postgres -n database --ignore-not-found
> kubectl delete pvc --all -n database
> ```
>
> Ensuite, continue avec les commandes ci-dessous.

Supprime les workloads du module 03 et réapplique avec la configuration externalisée :

```bash
# Appliquer ConfigMaps et Secrets
kubectl apply -f 04-configuration/manifests/postgres-configmap.yaml
kubectl apply -f 04-configuration/manifests/postgres-secret.yaml
kubectl apply -f 04-configuration/manifests/api-secret.yaml

# Réappliquer les workloads (maintenant sans valeurs en clair)
kubectl apply -f 04-configuration/manifests/postgres-statefulset.yaml
kubectl apply -f 04-configuration/manifests/api-deployment.yaml
```

Vérifie que les variables sont bien injectées :

```bash
kubectl exec -it postgres-0 -n database -- env | grep POSTGRES
```

```
POSTGRES_DB=usersdb
POSTGRES_USER=admin
POSTGRES_PASSWORD=S3cur3P@ssw0rd!
```

---

## Inspecter ConfigMaps et Secrets

```bash
# Lister
kubectl get configmap -n database
kubectl get secret -n database

# Voir le contenu d'un ConfigMap
kubectl get configmap postgres-config -n database -o yaml

# Décoder un Secret (base64)
kubectl get secret postgres-secret -n database -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

---

## Mise à jour dynamique

Quand un ConfigMap est monté en **volume**, les modifications sont répercutées dans le conteneur après un délai (kubelet sync period, environ 60s) **sans redémarrage du Pod**.

Quand il est injecté en **variable d'environnement**, il faut redémarrer le Pod pour que les changements soient pris en compte :

```bash
kubectl rollout restart deployment/api -n api
```

---

## Bonnes pratiques

- Ne jamais committer un Secret YAML en clair dans git — utiliser [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) ou [External Secrets Operator](https://external-secrets.io/)
- Préfixer les noms : `<app>-config`, `<app>-secret`
- Les ConfigMaps et Secrets sont **namespace-scoped** : un Pod ne peut référencer que ceux de son propre namespace

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **ConfigMap** | Configuration non-sensible sous forme clé/valeur ou fichiers |
| **Secret** | Données sensibles encodées en base64 |
| **envFrom** | Injecte toutes les clés d'un ConfigMap/Secret comme variables d'env |
| **Volume ConfigMap** | Monte les clés d'un ConfigMap comme fichiers dans un conteneur |
| **stringData** | Alias non-encodé pour remplir un Secret (Kubernetes encode à l'écriture) |

---

## Aller plus loin

- Sealed Secrets : chiffrement des Secrets pour les committer en git
- External Secrets Operator : synchronisation depuis Vault, AWS SM, GCP SM
- Kustomize : gestion de configurations par environnement sans dupliquer les manifests

---

**← Précédent** [Module 03 — Workloads](../03-workloads/README.md)  
**Suivant →** [Module 05 — Réseau interne](../05-networking/README.md)
