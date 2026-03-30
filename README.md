# Parcours Kubernetes — Du débutant à l'expert

Un parcours progressif pour maîtriser Kubernetes, de la création d'un Pod jusqu'au contrôle d'accès réseau avec Cilium et la Gateway API. Chaque module s'appuie sur un **fil rouge applicatif** composé de trois services réels.

---

## Fil rouge applicatif

L'ensemble du parcours gravite autour d'une application découpée en trois composants, chacun isolé dans son propre namespace :

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Cluster kind                                 │
│                                                                     │
│  ns/frontend          ns/api              ns/database               │
│  ┌───────────┐        ┌──────────┐        ┌────────────────────┐   │
│  │  Web UI   │──────▶│  Go API  │──────▶│    PostgreSQL        │   │
│  │ (Nginx)   │  HTTP  │ REST     │  SQL   │    StatefulSet      │   │
│  └───────────┘        └──────────┘        └────────────────────┘   │
│                                                                     │
│              Gateway API (Cilium)  ◀── trafic externe               │
└─────────────────────────────────────────────────────────────────────┘
```

| Composant | Namespace | Description |
|-----------|-----------|-------------|
| **PostgreSQL** | `database` | Base de données avec une table `users` |
| **API Go** | `api` | API REST minimaliste (`GET /users`, `POST /users`) |
| **Frontend** | `frontend` | Interface web HTML/JS pour consommer l'API |

Le code source de l'API et du frontend se trouve dans [`apps/`](./apps/).

---

## Environnement

- **Cluster** : [kind](https://kind.sigs.k8s.io/) — 1 control-plane + 2 workers
- **CNI** : [Cilium](https://cilium.io/) 1.19 avec Hubble relay activé
- **kubectl**, **helm**, **cilium CLI**

Pour initialiser l'environnement, voir le [module 00](./00-setup/README.md).

---

## Parcours

| Module | Titre | Concepts clés | Fil rouge |
|--------|-------|---------------|-----------|
| [00](./00-setup/README.md) | Setup de l'environnement | kind, Cilium, Hubble, kubectl | Cluster opérationnel |
| [01](./01-namespaces/README.md) | Namespaces | Namespace, isolation, kubectl config | Création des 3 namespaces |
| [02](./02-pods/README.md) | Pods | Pod, labels, annotations, logs, exec, lifecycle | Premier Pod PostgreSQL |
| [03](./03-workloads/README.md) | Workloads | Deployment, ReplicaSet, StatefulSet, DaemonSet | API + PostgreSQL en Deployment/StatefulSet |
| [04](./04-configuration/README.md) | Configuration | ConfigMap, Secret, variables d'environnement, volumes | Config PostgreSQL & API via ConfigMap/Secret |
| [05](./05-networking/README.md) | Réseau interne | Service (ClusterIP), DNS interne, kube-proxy | Communication API → PostgreSQL |
| [06](./06-storage/README.md) | Stockage | PersistentVolume, PVC, StorageClass | Persistance des données PostgreSQL |
| [07](./07-network-policies/README.md) | NetworkPolicies & Cilium | CiliumNetworkPolicy, Hubble observe, isolation L3/L4/L7 | Isolation des namespaces, whitelist par service |
| [08](./08-rbac/README.md) | RBAC | ServiceAccount, Role, RoleBinding, ClusterRole | ServiceAccount dédié par composant |
| [09](./09-gateway-api/README.md) | Gateway API | GatewayClass, Gateway, HTTPRoute, TCPRoute | Exposition de l'API et du frontend |
| [10](./10-observability/README.md) | Observabilité | Probes, Resources/Limits, HPA, Hubble UI | Robustesse et scalabilité de l'API |

---

## Progression des concepts

```
Débutant ──────────────────────────────────────────────── Expert
   │                                                          │
  [00]   [01]   [02]   [03]   [04]   [05]   [06]   [07]  [08][09][10]
 Setup  NS    Pods   Work   Conf   Net   Store  NetPol  RBAC GW  Obs
```

---

## Prérequis logiciels

```bash
# Vérifier les outils nécessaires
docker version          # Docker Desktop ou équivalent
kind version            # >= 0.20
kubectl version         # >= 1.29
helm version            # >= 3.14
cilium version          # CLI Cilium >= 0.16
```

Les instructions d'installation de chaque outil sont dans le [module 00](./00-setup/README.md).

---

## Images Docker

Les images des applications fil rouge sont publiées publiquement sur Docker Hub :

| Image | Repository |
|-------|------------|
| API Go | [`simonjaricot/k8s-tuto-api`](https://hub.docker.com/r/simonjaricot/k8s-tuto-api) |
| Frontend | [`simonjaricot/k8s-tuto-frontend`](https://hub.docker.com/r/simonjaricot/k8s-tuto-frontend) |

### Stratégie de versioning

Chaque image est poussée avec **deux tags** à chaque release :

```
simonjaricot/k8s-tuto-api:v1.0.2            ← tag semver (stable, référencé dans les manifests)
simonjaricot/k8s-tuto-api:v1.0.2-a1b2c3d   ← semver + SHA court (traçabilité exacte du commit)
```

> Le tag `latest` n'est **jamais** utilisé — il est non-déterministe et rend les déploiements
> difficiles à reproduire. Les manifests référencent toujours un tag semver précis.

---

## Conventions utilisées dans ce parcours

- Les manifests YAML se trouvent dans `<module>/manifests/`
- Chaque manifest est commenté et expliqué dans le README du module
- Les commandes `kubectl` sont accompagnées d'une explication de leur sortie attendue
- Les sections marquées **Fil rouge** montrent comment le concept s'intègre à l'application globale
- Les sections marquées **Aller plus loin** proposent des pistes d'approfondissement optionnelles
