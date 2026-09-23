# chill-crate-infra

Terraform and Kubernetes manifests for the chill-crate platform — MinIO, Keycloak, ArgoCD, and the database the API runs against.

Two environments run from this repo:

| | Cluster | Hostnames | Storage | Database |
|---|---|---|---|---|
| **dev** | baremetal RKE2 homelab | `dev.*.mikeflot.com` | local-path | in-cluster Postgres |
| **stg** | AWS EKS (`chill-crate-stg`) | `stg.*.mikeflot.com` | gp3 via EBS CSI | RDS |

Component directories hold the shared manifests; everything that differs between the two lives in `overlays/`. The stg environment is **disposable** — it's torn down between sessions and rebuilt with `make up`.

## Structure

```
.
├── Makefile                        # stg bootstrap and teardown — run `make help`
├── terraform/stg/                  # VPC, EKS, RDS, EBS CSI Pod Identity role
├── overlays/
│   ├── dev/                        # baremetal — passthrough, no patches
│   └── stg/                        # EKS — hostnames, gp3, RDS ExternalName
├── argocd/
│   ├── namespace.yaml
│   ├── kustomization.yaml          # upstream ArgoCD manifests + nodeSelector patch
│   ├── nodeselector-patch.yaml     # adds nodeSelector workload=heavy
│   └── image-updater/
│       └── image-updater.yaml      # ImageUpdater CR (controller installed via Helm)
├── argocd-apps/
│   ├── chill-crate-api-app.yaml     # dev Application
│   └── chill-crate-api-app-stg.yaml # stg Application — adds valueFiles: values-stg.yaml
├── cert-manager/
│   ├── clusterissuers.yaml         # letsencrypt-staging + letsencrypt-prod, Cloudflare DNS01
│   ├── secret.example.yaml
│   └── secret.yaml                 # gitignored — Cloudflare API token
├── chill-crate-api/
│   ├── secret.example.yaml
│   ├── secret.yaml                 # gitignored — the chart itself lives in the API repo
│   └── secret-dev.yaml             # gitignored
├── keycloak/                       # deployment, service, ingress, secret
├── minio/                          # deployment, service, pvc, secret
├── postgres/                       # dev only — stg uses RDS instead
├── ingress-nginx/
│   └── values-stg.yaml             # ingress-nginx behind an internet-facing NLB
├── monitoring/                     # kube-prometheus-stack values, base + stg
├── storage/
│   ├── local-path-storage.yaml     # dev — Rancher local-path-provisioner
│   └── storageclass-gp3.yaml       # stg — gp3 via the EBS CSI driver
└── namespace.yaml                  # chill-crate namespace
```

## Secrets

`secret.yaml` files are gitignored and created by hand per cluster. They're deliberately left out of the `kustomization.yaml` files so `kustomize build` works on a fresh clone.

```bash
cp minio/secret.example.yaml         minio/secret.yaml
cp keycloak/secret.example.yaml      keycloak/secret.yaml
cp cert-manager/secret.example.yaml  cert-manager/secret.yaml
cp chill-crate-api/secret.example.yaml chill-crate-api/secret.yaml
# dev also needs postgres/secret.yaml; stg does not
```

Two things that aren't obvious:

- **`DB_PASSWORD` is not in `chill-crate-api/secret.yaml`.** RDS generates a new master password on every `terraform apply`, so `make secrets` pulls it from Secrets Manager and patches it in. Anything hardcoded there would be stale after each rebuild.
- **`KC_DB_URL` needs `?sslmode=require` on stg.** RDS sets `rds.force_ssl = 1` and the PostgreSQL JDBC driver doesn't negotiate TLS on its own. Without it Keycloak is refused before authentication, and the error looks like a bad password.

---

## AWS EKS (stg)

Everything is driven from the Makefile. `make help` lists the targets.

### Phase 1 — infrastructure and platform

```bash
make aws-login      # if credentials have lapsed
make up             # terraform apply, kubeconfig, storage, platform, print NLB
```

`up` chains `apply → kubeconfig → storage → platform → nlb`. Terraform builds the VPC, EKS cluster, spot node group (labelled `workload=heavy`) and RDS; then cert-manager, ingress-nginx and ArgoCD go in; then the NLB hostname is printed.

### Phase 2 — DNS (manual)

Point both records at the NLB hostname `make up` printed:

| Record | Type | Target | Proxy |
|---|---|---|---|
| `stg.keycloak` | CNAME | the NLB hostname | **DNS only (grey)** |
| `stg.chill-crate-api` | CNAME | the NLB hostname | **DNS only (grey)** |

The hostname is different on every rebuild, so these have to be updated each time. `make nlb` reprints it.

Grey cloud matters twice over. Cloudflare's Universal SSL covers `mikeflot.com` and `*.mikeflot.com` but **not** `*.*.mikeflot.com` — a proxied two-label subdomain fails TLS at the edge while HTTP still works. And Keycloak runs `KC_PROXY_HEADERS=xforwarded` expecting nginx to be the proxy; a second hop gets its redirect and issuer URLs subtly wrong.

Verify before continuing — you want A records under the CNAME, not just the CNAME line:

```bash
dig +short stg.keycloak.mikeflot.com
```

### Phase 3 — workloads

```bash
make deploy         # secrets, db-init, workloads, ArgoCD Application
```

`deploy` chains `secrets → db-init → workloads → app`. `db-init` creates the `keycloak` role and database on RDS (idempotent); `workloads` substitutes the RDS endpoint into the `postgres` ExternalName Service and applies the stg overlay; `app` hands the API to ArgoCD.

### Phase 4 — Keycloak realm (manual)

Log in at `https://stg.keycloak.mikeflot.com` with the `KC_BOOTSTRAP_ADMIN_*` credentials from `keycloak-secret`, then create:

- a realm whose **Realm ID** is exactly `chill-crate` (the ID is what appears in `/realms/<id>/`, not the display name — and a trailing space will cost you an hour)
- a confidential client `chill-crate-api` whose secret matches `KEYCLOAK_CLIENT_SECRET`, with `https://stg.chill-crate-api.mikeflot.com/*` in its valid redirect URIs

This is the last step nothing automates. Exporting the realm to JSON and mounting it with `--import-realm` would close it.

### Optional

```bash
make monitoring     # kube-prometheus-stack — heavy on two nodes
make image-updater  # ArgoCD Image Updater controller + CR
```

---

## Baremetal (dev)

The homelab cluster is long-lived and has no Makefile targets.

```bash
kubectl apply -f storage/local-path-storage.yaml
kubectl apply -f namespace.yaml
kubectl apply -f postgres/secret.yaml -f minio/secret.yaml -f keycloak/secret.yaml
kubectl apply -k overlays/dev

kubectl apply -k argocd/ --server-side --force-conflicts
kubectl apply -f argocd-apps/chill-crate-api-app.yaml
```

---

## Teardown

```bash
make destroy        # deletes LoadBalancer Services first, then terraform destroy
make verify         # lists anything still billing
```

`destroy` removes LoadBalancer Services **before** Terraform runs, because the NLB is created by the Kubernetes cloud controller and Terraform doesn't know it exists. Skip that and `terraform destroy` fails detaching the internet gateway (`DependencyViolation: has some mapped public address(es)`), leaving an orphaned NLB billing at ~$16/month.

`make verify` should print nothing under every heading.

---

## How deployments work

1. A push to `main` in `chill-crate-api` triggers CI, which builds and pushes to `ghcr.io/mic615/chill-crate-api:latest`.
2. ArgoCD Image Updater detects the new digest and updates the Application in-cluster.
3. ArgoCD syncs the chart with the new tag.

The chart lives in the API repo at `deploy/chart` and is versioned with the code. Environment differences go in `values-stg.yaml`, selected by the stg Application's `valueFiles`. **ArgoCD reads from GitHub, not your working tree** — chart changes must be pushed before they take effect.

---

## Troubleshooting

Things that have cost real time here:

**Node group fails with `NodeCreationFailure: Unhealthy nodes`** — the CNI never installed. `vpc-cni` and `kube-proxy` need `before_compute = true`, or the module creates addons *after* the node group and the nodes sit `NotReady` waiting for a network plugin that Terraform won't install until they're Ready.

**NLB won't provision, `Multiple tagged security groups found for instance`** — `attach_cluster_primary_security_group` must be `false`. With it on, nodes carry two security groups both tagged `kubernetes.io/cluster/<name>` and the in-tree cloud controller refuses to guess.

**TLS handshake failure, but HTTP works** — almost always the Cloudflare proxy on a two-label subdomain. Check with `dig`: Cloudflare IPs (`104.x`, `172.67.x`) mean it's still orange.

**TLS handshake failure from macOS only** — the system LibreSSL has TLS 1.3 interop bugs and reports a misleading server-side failure. Retest with `curl --tlsv1.2 --tls-max 1.2`, or from inside a pod, before believing it.

**Keycloak crashloops with `password authentication failed for user "keycloak"`** — the role doesn't exist on a fresh RDS instance. Run `make db-init`.

**ArgoCD install fails with `metadata.annotations: Too long`** — client-side apply can't hold its CRDs. Use `--server-side --force-conflicts`.

---

## Known gaps

- **The Keycloak realm and client are created by hand.** A realm export committed here and imported at startup would remove the last manual step.
- **DNS is manual** and changes on every rebuild. external-dns with the Cloudflare provider would automate it using the token cert-manager already has.
- **Secrets live in gitignored files**, so a fresh clone can't rebuild without them. AWS Secrets Manager plus External Secrets Operator is the natural next step — `DB_PASSWORD` already works this way.
- **The image-updater chart version isn't pinned** — only the image tag (`v1.2.2`) is.
- **RDS shares state with the cluster** and `skip_final_snapshot = true`, so `make destroy` takes the data with it. Deliberate while stg is disposable; flip both if it ever holds anything worth keeping.
