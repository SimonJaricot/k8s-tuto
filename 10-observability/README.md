# Module 10 — Observabilité

**Objectif** : rendre l'application robuste et observable en ajoutant des health probes, des limites de ressources, un autoscaling horizontal, et en explorant Hubble UI pour visualiser le trafic réseau.

---

## Pourquoi l'observabilité ?

Sans observabilité, un Pod peut :
- Répondre avec des erreurs sans être redémarré automatiquement
- Consommer toute la mémoire d'un nœud et provoquer des évictions
- Ne jamais recevoir de trafic parce que le Service le considère `NotReady`

Les outils d'observabilité permettent à Kubernetes de **réagir automatiquement** aux défaillances.

---

## Health Probes

Kubernetes propose trois types de sondes pour évaluer l'état d'un conteneur :

| Sonde | Rôle | Action en cas d'échec |
|-------|------|----------------------|
| `livenessProbe` | Le conteneur est-il vivant ? | Redémarre le conteneur |
| `readinessProbe` | Le conteneur est-il prêt à recevoir du trafic ? | Retire le Pod des Endpoints du Service |
| `startupProbe` | Le conteneur a-t-il fini de démarrer ? | Désactive liveness/readiness pendant le démarrage |

### Types de sondes

```yaml
# HTTP GET — idéal pour les APIs
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5    # Attendre 5s avant la première vérification
  periodSeconds: 10         # Vérifier toutes les 10s
  failureThreshold: 3       # 3 échecs → redémarrage

# TCP socket — pour PostgreSQL
livenessProbe:
  tcpSocket:
    port: 5432
  initialDelaySeconds: 15
  periodSeconds: 20

# Commande exec
readinessProbe:
  exec:
    command: ["pg_isready", "-U", "admin", "-d", "usersdb"]
  initialDelaySeconds: 5
  periodSeconds: 5
```

---

## Fil rouge — Ajouter des probes

### PostgreSQL

```yaml
# Dans le StatefulSet postgres
containers:
  - name: postgres
    livenessProbe:
      exec:
        command: ["pg_isready", "-U", "$(POSTGRES_USER)", "-d", "$(POSTGRES_DB)"]
      initialDelaySeconds: 30
      periodSeconds: 10
      failureThreshold: 3
    readinessProbe:
      exec:
        command: ["pg_isready", "-U", "$(POSTGRES_USER)", "-d", "$(POSTGRES_DB)"]
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 3
```

### API Go

```yaml
containers:
  - name: api
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 10
    readinessProbe:
      httpGet:
        path: /readyz
        port: 8080
      initialDelaySeconds: 3
      periodSeconds: 5
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30    # 30 * 2s = 60s max pour démarrer
      periodSeconds: 2
```

> `/healthz` répond toujours `200 OK` si le processus tourne. `/readyz` vérifie aussi la connexion à la base de données.

---

## Limites de ressources

Sans limites, un Pod peut consommer toutes les ressources d'un nœud et en priver les autres. Kubernetes distingue deux notions :

| Notion | Description | Comportement si dépassé |
|--------|-------------|------------------------|
| `requests` | Ressources **garanties** — utilisées pour le scheduling | Nœud assigné en conséquence |
| `limits` | Ressources **maximales** — le Pod ne peut pas dépasser | CPU throttled, RAM → OOMKilled |

```yaml
containers:
  - name: api
    resources:
      requests:
        cpu: "100m"       # 0.1 vCPU
        memory: "64Mi"
      limits:
        cpu: "500m"       # 0.5 vCPU
        memory: "128Mi"
```

> `100m` = 100 millicores = 0.1 cœur CPU.

### Recommandations par composant

| Composant | requests CPU | requests RAM | limits CPU | limits RAM |
|-----------|-------------|--------------|------------|------------|
| postgres | 250m | 256Mi | 1000m | 512Mi |
| api (par réplica) | 100m | 64Mi | 500m | 128Mi |
| frontend | 50m | 32Mi | 200m | 64Mi |

```bash
# Voir la consommation réelle (nécessite metrics-server)
kubectl top pods -n api
kubectl top pods -n database
```

> **metrics-server non installé par défaut dans kind** : sans lui, `kubectl top` échoue avec `error: Metrics API not available` et le HPA affiche `cpu: <unknown>`. Pour l'installer :
>
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
>
> # Patch obligatoire pour kind (certificats TLS auto-signés)
> kubectl patch deployment metrics-server -n kube-system \
>   --type=json \
>   -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
> ```

---

## Horizontal Pod Autoscaler (HPA)

Le **HPA** scale automatiquement le nombre de réplicas d'un Deployment en fonction de métriques (CPU, RAM, métriques custom).

```yaml
# manifests/api-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
  namespace: api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70    # Scale up si CPU > 70%
    - type: Resource
      resource:
        name: memory
        target:
          type: AverageValue
          averageValue: 100Mi
```

> Le HPA nécessite que le Deployment ait des `requests` de ressources définies.

```bash
kubectl apply -f 10-observability/manifests/api-hpa.yaml

# Observer le HPA
kubectl get hpa -n api -w
```

```
NAME      REFERENCE         TARGETS               MINPODS   MAXPODS   REPLICAS
api-hpa   Deployment/api    <unknown>/70%, ...    2         10        2
```

> Sans metrics-server, les colonnes `TARGETS` affichent `<unknown>`. Installe metrics-server (voir ci-dessus) pour voir les valeurs réelles (`12%/70%`).

### Générer de la charge pour tester le HPA

```bash
# Dans un terminal séparé — générer des requêtes
kubectl run load-gen --image=busybox --rm -it --restart=Never -- \
  sh -c "while true; do wget -q -O- http://api.api.svc.cluster.local:8080/users; done"
```

Observer le scale-up dans un autre terminal :

```bash
kubectl get pods -n api -w
```

---

## Hubble UI — Visualisation réseau

```bash
# Activer Hubble UI si pas encore fait
cilium hubble enable --ui

# Ouvrir l'interface (port-forward automatique)
cilium hubble ui
```

L'interface affiche :
- Un **graphe en temps réel** des flux entre services
- Les flux **FORWARDED** (vert) et **DROPPED** (rouge)
- Les métriques de trafic par service

Avec l'application fil rouge complètement déployée et les NetworkPolicies du module 07 actives, Hubble UI affiche :

```
[frontend] ──(HTTP GET /users)──▶ [api] ──(TCP 5432)──▶ [postgres]
              FORWARDED                    FORWARDED

[frontend] ──────────────────────────────────────────▶ [postgres]
              DROPPED (Policy denied)
```

---

## Récapitulatif — Manifests du module 10

```bash
kubectl apply -f 10-observability/manifests/
```

Contenu :
- `postgres-statefulset.yaml` : StatefulSet avec probes + resources
- `api-deployment.yaml` : Deployment avec probes + resources
- `frontend-deployment.yaml` : Deployment avec probes + resources
- `api-hpa.yaml` : HPA pour l'API

---

## État final du fil rouge

A ce stade, l'application complète est déployée avec :

| Module | Apport |
|--------|--------|
| 01 | Namespaces isolés |
| 02-03 | Pods, Deployments, StatefulSet |
| 04 | Configuration externalisée (ConfigMap/Secret) |
| 05 | Services et DNS interne |
| 06 | Stockage persistant (PVC) |
| 07 | Isolation réseau (CiliumNetworkPolicy) |
| 08 | Identités applicatives (ServiceAccount, RBAC) |
| 09 | Exposition externe (Gateway API) |
| 10 | Robustesse (probes, resources, HPA) |

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **livenessProbe** | Détecte un conteneur bloqué — le redémarre |
| **readinessProbe** | Contrôle si un Pod peut recevoir du trafic |
| **startupProbe** | Laisse le temps à l'application de démarrer |
| **requests / limits** | Ressources garanties vs maximales |
| **HPA** | Autoscaling horizontal basé sur des métriques |
| **Hubble UI** | Interface graphique de visualisation des flux réseau |

---

## Aller plus loin

- **Vertical Pod Autoscaler (VPA)** : ajuste automatiquement les `requests/limits`
- **KEDA** : autoscaling sur métriques custom (queues, Prometheus, HTTP RPS…)
- **Prometheus + Grafana** : métriques applicatives et dashboards
- **OpenTelemetry** : traces distribuées à travers les services
- **PodDisruptionBudget** : garantit un nombre minimum de Pods disponibles lors des maintenances

---

**← Précédent** [Module 09 — Gateway API](../09-gateway-api/README.md)  
**Retour au sommaire** [README principal](../README.md)
