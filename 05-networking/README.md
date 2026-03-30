# Module 05 — Réseau interne

**Objectif** : comprendre comment les Pods communiquent entre eux via les Services et le DNS interne de Kubernetes, et relier l'API Go à PostgreSQL.

---

## Le réseau des Pods

Dans Kubernetes, chaque Pod reçoit une **adresse IP unique** dans le cluster (gérée par Cilium dans notre cas). Mais cette IP est **éphémère** : elle change à chaque recréation du Pod.

```
postgres-0  →  IP: 10.0.1.5   (aujourd'hui)
postgres-0  →  IP: 10.0.1.12  (après redémarrage)
```

On ne peut donc pas coder en dur l'IP d'un Pod. C'est le rôle des **Services**.

---

## Service — La découverte de services stable

Un **Service** est une abstraction qui expose un ensemble de Pods sous une **IP virtuelle stable** (ClusterIP) et un **nom DNS** résolvable depuis n'importe quel Pod du cluster.

```
api Pod  ──▶  Service postgres (ClusterIP: 10.96.0.50)
                      │
              ┌───────┴───────┐
          postgres-0      (postgres-1, si plusieurs réplicas)
```

### Types de Services

| Type | Accessible depuis | Usage |
|------|------------------|-------|
| `ClusterIP` | À l'intérieur du cluster uniquement | Communication inter-services (par défaut) |
| `NodePort` | Depuis l'extérieur via `<NodeIP>:<port>` | Debug, accès direct sans load balancer |
| `LoadBalancer` | Depuis l'extérieur via une IP publique | Cloud providers (GKE, EKS, AKS…) |
| `ExternalName` | Redirige vers un nom DNS externe | Abstraction vers des services externes |

---

## ClusterIP — Communication interne

```yaml
# manifests/postgres-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: database
spec:
  type: ClusterIP      # Par défaut
  selector:
    app: postgres      # Sélectionne les Pods avec ce label
  ports:
    - port: 5432       # Port du Service
      targetPort: 5432 # Port du conteneur
      protocol: TCP
```

Le sélecteur `app: postgres` fait le lien entre le Service et les Pods. Kubernetes maintient automatiquement la liste des **Endpoints** (IPs des Pods sains) derrière ce Service.

```bash
# Voir les Endpoints derrière un Service
kubectl get endpoints postgres -n database
```

```
NAME       ENDPOINTS         AGE
postgres   10.0.1.5:5432     30s
```

---

## Headless Service (StatefulSet)

Pour un **StatefulSet**, on utilise souvent un **Headless Service** (`clusterIP: None`). Il ne crée pas d'IP virtuelle mais enregistre un **enregistrement DNS par Pod** :

```
postgres-0.postgres.database.svc.cluster.local  →  10.0.1.5
postgres-1.postgres.database.svc.cluster.local  →  10.0.1.6
```

```yaml
# manifests/postgres-headless-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: database
spec:
  clusterIP: None    # Headless
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
```

> Le `serviceName: postgres` dans le StatefulSet (module 03) fait référence à ce Headless Service.

---

## DNS interne — kube-dns / CoreDNS

Kubernetes inclut un serveur DNS interne (CoreDNS) qui résout automatiquement les noms de Services.

**Format du nom DNS complet :**
```
<service-name>.<namespace>.svc.cluster.local
```

**Exemples :**
```
postgres.database.svc.cluster.local   ← depuis n'importe quel namespace
postgres.database                     ← raccourci (même cluster domain)
postgres                              ← uniquement depuis le namespace database
```

C'est pourquoi dans le ConfigMap de l'API (module 04), on a mis :
```
DB_HOST: "postgres.database.svc.cluster.local"
```

### Tester la résolution DNS depuis un Pod

```bash
# Lancer un Pod de debug temporaire
kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never -- sh

# Depuis le shell du Pod
nslookup postgres.database.svc.cluster.local
```

```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      postgres.database.svc.cluster.local
Address 1: 10.96.0.50
```

---

## Fil rouge — Connecter l'API à PostgreSQL

> **Prérequis** : les modules 03 et 04 doivent avoir été appliqués dans l'ordre avant ce module.
> - Module 03 : StatefulSet PostgreSQL + Deployment API
> - Module 04 : ConfigMap et Secret (le mot de passe PostgreSQL vient du Secret `postgres-secret`)
>
> Si tu appliques le module 05 sans le module 04, l'API aura `DB_PASSWORD: changeme` en dur (module 03) mais PostgreSQL attendra le mot de passe du Secret — entraînant une erreur `password authentication failed`.

Applique les Services :

```bash
kubectl apply -f 05-networking/manifests/
```

Vérifie que l'API peut joindre PostgreSQL :

```bash
# Depuis un Pod de l'API, tester la connexion
kubectl exec -it deploy/api -n api -- wget -qO- http://localhost:8080/healthz
```

```json
{"status": "ok", "db": "connected"}
```

### Vérifier les Services

```bash
kubectl get services -n database
```

```
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE
postgres   ClusterIP   None         <none>        5432/TCP   30s
```

```bash
kubectl get services -n api
```

```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
api    ClusterIP   10.96.45.123   <none>        8080/TCP   30s
```

---

## Service pour le frontend

```yaml
# manifests/frontend-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: frontend
spec:
  type: ClusterIP
  selector:
    app: frontend
  ports:
    - port: 80
      targetPort: 80
```

---

## NodePort — Accès temporaire pour les tests

Pour tester depuis la machine hôte sans Gateway ni Ingress :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-nodeport
  namespace: api
spec:
  type: NodePort
  selector:
    app: api
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 30080   # Port sur les nœuds kind (30000-32767)
```

Avec kind, accéder via :
```bash
# Obtenir l'IP d'un nœud worker
kubectl get nodes -o wide

curl http://<NODE_IP>:30080/users
```

> En production, on n'expose pas les applications via NodePort. C'est le rôle de la Gateway API (module 09).

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **Service** | Abstraction stable devant un groupe de Pods |
| **ClusterIP** | IP virtuelle interne au cluster |
| **Headless Service** | Service sans IP virtuelle, enregistre un DNS par Pod |
| **Endpoints** | Liste des IPs réelles des Pods derrière un Service |
| **CoreDNS** | Serveur DNS interne qui résout les noms de Services |
| **NodePort** | Expose un Service sur un port de chaque nœud |

---

## Aller plus loin

- `kubectl port-forward svc/postgres 5432:5432 -n database` : accéder à un Service depuis sa machine locale
- EndpointSlices : remplaçant moderne des Endpoints pour de grandes topologies
- Service topology / Traffic Policy : router le trafic vers les Pods du même nœud

---

**← Précédent** [Module 04 — Configuration](../04-configuration/README.md)  
**Suivant →** [Module 06 — Stockage](../06-storage/README.md)
