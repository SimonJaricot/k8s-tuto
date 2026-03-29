# Module 00 — Setup de l'environnement

**Objectif** : disposer d'un cluster Kubernetes local fonctionnel avec Cilium comme CNI et Hubble pour l'observabilité réseau.

---

## Prérequis

Installe les outils suivants avant de commencer :

### Docker

```bash
# macOS
brew install --cask docker
# Vérifie
docker version
```

### kind

```bash
# macOS
brew install kind
# Vérifie
kind version   # >= 0.20
```

### kubectl

```bash
# macOS
brew install kubectl
# Vérifie
kubectl version --client
```

### Helm

```bash
# macOS
brew install helm
# Vérifie
helm version   # >= 3.14
```

### Cilium CLI

```bash
# macOS
brew install cilium-cli
# Vérifie
cilium version
```

---

## Créer le cluster

Le fichier [`kind-config.yaml`](../kind-config.yaml) définit un cluster avec :
- 1 nœud control-plane
- 2 nœuds workers
- Le CNI par défaut (`kindnet`) **désactivé** pour laisser Cilium prendre la main

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
networking:
  disableDefaultCNI: true
```

> **Pourquoi désactiver le CNI par défaut ?**
> kind installe `kindnet` automatiquement. Pour que Cilium gère le réseau des Pods (et puisse appliquer des NetworkPolicies L7), il faut qu'il soit le seul CNI présent.

Le script [`init.sh`](../init.sh) automatise l'ensemble de la procédure :

```bash
chmod +x init.sh
./init.sh
```

Ce qu'il fait :
1. Crée le cluster kind sans CNI
2. Configure le contexte kubectl
3. Ajoute le repo Helm Cilium
4. Installe Cilium 1.19 avec Hubble relay activé
5. Attend que les DaemonSets soient `Ready`

---

## Vérifier l'installation

### Les nœuds sont `Ready`

```bash
kubectl get nodes
```

Sortie attendue :

```
NAME                 STATUS   ROLES           AGE   VERSION
kind-control-plane   Ready    control-plane   2m    v1.32.x
kind-worker          Ready    <none>          2m    v1.32.x
kind-worker2         Ready    <none>          2m    v1.32.x
```

> Les nœuds passent en `Ready` uniquement une fois que Cilium a installé les interfaces réseau sur chaque nœud.

### Cilium est opérationnel

```bash
cilium status --wait
```

Sortie attendue (résumé) :

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    disabled
 \__/¯¯\__/    Hubble Relay:       OK
    \__/
```

### Hubble relay est accessible

```bash
cilium hubble port-forward &
hubble status
```

Sortie attendue :

```
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 4096/4096
Flows/s: 12.34
Connected Nodes: 3/3
```

---

## Anatomie du cluster

```
┌─────────────────────────────────────────────────────┐
│  kind-control-plane                                  │
│  ├── kube-apiserver                                  │
│  ├── kube-controller-manager                         │
│  ├── kube-scheduler                                  │
│  └── etcd                                            │
│                                                      │
│  kind-worker / kind-worker2                          │
│  ├── kubelet                                         │
│  ├── cilium (DaemonSet)      ← gère le réseau        │
│  └── hubble (DaemonSet)      ← observe le trafic     │
└─────────────────────────────────────────────────────┘
```

---

## Concepts introduits

| Concept | Description |
|---------|-------------|
| **kind** | Kubernetes IN Docker — crée un cluster en utilisant des conteneurs comme nœuds |
| **CNI** | Container Network Interface — plugin réseau qui gère la connectivité entre Pods |
| **Cilium** | CNI basé sur eBPF, remplace iptables pour le filtrage réseau |
| **Hubble** | Couche d'observabilité de Cilium — visualise les flux réseau en temps réel |
| **DaemonSet** | Ressource Kubernetes qui garantit qu'un Pod tourne sur chaque nœud (utilisé par Cilium) |
| **kubectl context** | Pointe vers quel cluster kubectl envoie ses commandes |

---

## Aller plus loin

- Hubble UI (interface graphique) : `cilium hubble enable --ui` puis `cilium hubble ui`
- Explorer les composants système : `kubectl get pods -n kube-system`
- Inspecter la configuration Cilium : `kubectl get configmap -n kube-system cilium-config -o yaml`

---

**Suivant →** [Module 01 — Namespaces](../01-namespaces/README.md)
