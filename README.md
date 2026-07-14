# chill-crate-infra

Kubernetes manifests for the chill-crate platform. Manages Postgres, MinIO, Keycloak and the ArgoCD GitOps setup that deploys the API.

## Structure

```
.
├── argocd/
│   ├── kustomization.yaml         # installs ArgoCD itself (upstream manifests) patched with the heavy-workload nodeSelector
│   ├── nodeselector-patch.yaml    # JSON6902 patch adding nodeSelector workload=heavy to ArgoCD Deployments/StatefulSets
│   └── image-updater/
│       └── image-updater.yaml     # ArgoCD Image Updater — watches ghcr.io and updates image digest on push
├── argocd-apps/
│   └── chill-crate-api-app.yaml   # ArgoCD Application — syncs the API Helm chart from chill-crate-api repo
├── keycloak/
│   ├── deployment.yaml            # sized/affined for the "heavy" node; requests 1700Mi/500m, limits 2Gi/2000m
│   ├── service.yaml
│   ├── ingress.yaml               # dev.keycloak.mikeflot.com, TLS via letsencrypt-prod
│   ├── secret.example.yaml        # copy to secret.yaml and fill in credentials
│   └── secret.yaml                # gitignored
├── minio/
│   ├── deployment.yaml
│   ├── pvc.yaml
│   ├── service.yaml               # ports 9000 (API) and 9001 (console)
│   ├── secret.example.yaml        # copy to secret.yaml and fill in credentials
│   └── secret.yaml                # gitignored
├── postgres/
│   ├── deployment.yaml            # postgres:16 with readiness probe
│   ├── pvc.yaml
│   ├── service.yaml               # port 5432
│   ├── secret.example.yaml        # copy to secret.yaml and fill in credentials
│   └── secret.yaml                # gitignored
├── storage/
│   └── local-path-storage.yaml    # Rancher local-path-provisioner (default StorageClass)
└── namespace.yaml                 # chill-crate namespace
```

## First-time setup

### 1. Storage provisioner

The cluster needs a default StorageClass before PVCs can bind. Apply the local-path-provisioner once:

```bash
kubectl apply -f storage/local-path-storage.yaml
```

### 2. Namespace

```bash
kubectl apply -f namespace.yaml
```

### 3. Secrets

Copy the example files and fill in real values:

```bash
cp postgres/secret.example.yaml postgres/secret.yaml
cp minio/secret.example.yaml minio/secret.yaml
# edit both files, then:
kubectl apply -f postgres/secret.yaml
kubectl apply -f minio/secret.yaml
```

The `secret.yaml` files are gitignored and must be created manually on each cluster.

### 4. Database and Storage

```bash
kubectl apply -f postgres/
kubectl apply -f minio/
```

### 5. ArgoCD

Install ArgoCD itself (pulled from the upstream manifests and patched to schedule onto the `workload: heavy` node), then apply the Application and Image Updater:

```bash
kubectl apply -k argocd/ --server-side --force-conflicts
kubectl apply -f argocd-apps/chill-crate-api-app.yaml
kubectl apply -f argocd/image-updater/image-updater.yaml
```

ArgoCD will sync the API from the `deploy/chart` path in the [chill-crate-api](https://github.com/mic615/chill-crate-api) repo and keep it up to date whenever a new image is pushed to `ghcr.io/mic615/chill-crate-api`.

### 6. Keycloak

```bash
cp keycloak/secret.example.yaml keycloak/secret.yaml
# edit keycloak/secret.yaml, then:
kubectl apply -f keycloak/secret.yaml
kubectl apply -f keycloak/
```

## How deployments work

1. A push to `main` in `chill-crate-api` triggers CI, which builds and pushes a new image digest to `ghcr.io/mic615/chill-crate-api:latest`.
2. ArgoCD Image Updater detects the new digest and updates the ArgoCD Application in-cluster.
3. ArgoCD syncs the Helm chart with the new image tag — no manual intervention needed.
