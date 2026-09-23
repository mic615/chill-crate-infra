# chill-crate-infra -- AWS (stg) bootstrap
#
#   make up       phase 1: AWS infra + cluster platform. Ends by printing the NLB.
#   <manual>      point Cloudflare CNAMEs at that NLB -- DNS only, grey cloud
#   make deploy   phase 2: secrets, database, workloads, hand off to ArgoCD
#   <manual>      create the Keycloak realm + client (not yet exported to JSON)
#
# Every kubectl/helm target guards on check-context, which compares the current
# kubeconfig server against terraform's cluster_endpoint. A stray context fails
# loudly rather than applying stg manifests to the homelab.

SHELL       := bash
.SHELLFLAGS := -eu -o pipefail -c

# Prerequisites only run left-to-right in serial mode, and several targets rely
# on that ordering (kubeconfig has to land before anything calling check-context).
.NOTPARALLEL:

ENV     ?= stg
REGION  ?= us-west-2
CLUSTER ?= chill-crate-$(ENV)
NS      ?= chill-crate
DB_USER ?= ccadmin

TF := terraform -chdir=terraform/$(ENV)

.DEFAULT_GOAL := help

.PHONY: help up deploy aws-login init plan fmt validate apply kubeconfig \
        check-context storage platform cert-manager ingress argo image-updater \
         monitoring nlb namespace secrets db-init workloads app destroy verify

# ---------------------------------------------------------------------------
# Meta
# ---------------------------------------------------------------------------

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: apply kubeconfig storage platform nlb ## Phase 1 -- infra + platform, then set DNS

deploy: secrets db-init workloads app ## Phase 2 -- secrets, database, workloads, ArgoCD

# ---------------------------------------------------------------------------
# AWS / Terraform
# ---------------------------------------------------------------------------

aws-login: ## Refresh local AWS credentials (opens a browser)
	aws login

init: ## terraform init
	$(TF) init

plan: ## terraform plan
	$(TF) plan

fmt: ## terraform fmt
	$(TF) fmt

validate: ## terraform validate
	$(TF) validate

apply: ## Provision VPC, EKS and RDS
	$(TF) apply

kubeconfig: ## Point kubectl at the EKS cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER) --alias $(CLUSTER)

check-context: ## Fail unless kubectl is pointed at this cluster
	@test "$$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" \
	   = "$$($(TF) output -raw cluster_endpoint)" \
	  || { echo "Wrong context: $$(kubectl config current-context)"; exit 1; }

# ---------------------------------------------------------------------------
# Cluster platform
# ---------------------------------------------------------------------------

storage: check-context ## Make gp3 the default StorageClass
	kubectl patch storageclass gp2 \
	  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
	kubectl apply -f storage/storageclass-gp3.yaml

platform: cert-manager ingress argo ## cert-manager, ingress-nginx and ArgoCD

cert-manager: check-context ## cert-manager + Cloudflare token + ClusterIssuers
	helm repo add jetstack https://charts.jetstack.io
	helm repo update
	helm upgrade --install cert-manager jetstack/cert-manager \
	  --namespace cert-manager --create-namespace \
	  --version v1.16.2 --set crds.enabled=true
	kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
	kubectl apply -f cert-manager/secret.yaml
	kubectl apply -f cert-manager/clusterissuers.yaml

ingress: check-context ## ingress-nginx behind an internet-facing NLB
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo update
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
	  --namespace ingress-nginx --create-namespace \
	  -f ingress-nginx/values-$(ENV).yaml

argo: check-context ## Install ArgoCD
	kubectl apply -k argocd/ --server-side --force-conflicts
	kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

image-updater: argo ## ArgoCD Image Updater controller, then its ImageUpdater CR
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	helm upgrade --install argocd-image-updater argo/argocd-image-updater \
	  --namespace argocd --set image.tag=v1.2.2
	kubectl apply -f argocd/image-updater/image-updater.yaml

monitoring: check-context ## kube-prometheus-stack (opt-in; heavy on two nodes)
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
	  --namespace monitoring --create-namespace \
	  -f monitoring/monitoring-values.yaml \
	  -f monitoring/monitoring-values-$(ENV).yaml

nlb: check-context ## Print the NLB hostname for the Cloudflare CNAMEs
	@kubectl -n ingress-nginx get svc ingress-nginx-controller \
	  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

namespace: check-context ## Create the chill-crate namespace
	kubectl apply -f namespace.yaml

secrets: namespace ## Apply secrets; DB_PASSWORD is injected from the RDS master secret
	kubectl apply -f minio/secret.yaml -f keycloak/secret.yaml -f chill-crate-api/secret.yaml
	@RDS_PW="$$(aws secretsmanager get-secret-value \
	    --secret-id "$$($(TF) output -raw db_rds_secret_arn)" \
	    --query SecretString --output text | jq -r .password)"; \
	kubectl -n $(NS) patch secret chill-crate-secret \
	  -p "{\"stringData\":{\"DB_PASSWORD\":\"$$RDS_PW\"}}"

db-init: secrets ## Create the keycloak role and database on RDS (idempotent)
	@KC_PW="$$(kubectl -n $(NS) get secret keycloak-secret \
	    -o jsonpath='{.data.KC_DB_PASSWORD}' | base64 -d)"; \
	RDS_PW="$$(aws secretsmanager get-secret-value \
	    --secret-id "$$($(TF) output -raw db_rds_secret_arn)" \
	    --query SecretString --output text | jq -r .password)"; \
	DB_HOST="$$($(TF) output -raw db_address)"; \
	kubectl -n $(NS) run psql-init --rm -i --restart=Never --image=postgres:16 \
	  --env=PGPASSWORD="$$RDS_PW" -- \
	  psql -h "$$DB_HOST" -U $(DB_USER) -d chillcrate -v ON_ERROR_STOP=1 \
	    -v kcpw="$$KC_PW" < keycloak/db-init.sql

workloads: secrets ## MinIO, Keycloak, and the RDS pointer
	@DB_HOST="$$($(TF) output -raw db_address)"; \
	kubectl kustomize overlays/$(ENV) \
	  | sed "s|__DB_ADDRESS__|$$DB_HOST|" \
	  | kubectl apply -f -

app: argo ## Hand the API over to ArgoCD
	kubectl apply -f argocd-apps/chill-crate-api-app-$(ENV).yaml

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

destroy: check-context ## Delete LoadBalancers, then terraform destroy
	-kubectl delete svc -A --field-selector spec.type=LoadBalancer --timeout=120s
	$(TF) destroy

verify: ## After destroy -- list anything still billing
	@echo "load balancers:"; aws elbv2 describe-load-balancers \
	  --query 'LoadBalancers[].LoadBalancerName' --output text
	@echo "unattached volumes:"; aws ec2 describe-volumes \
	  --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
	@echo "elastic IPs:"; aws ec2 describe-addresses \
	  --query 'Addresses[].PublicIp' --output text
	@echo "rds:"; aws rds describe-db-instances \
	  --query 'DBInstances[].DBInstanceIdentifier' --output text
	@echo "nat gateways:"; aws ec2 describe-nat-gateways \
	  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
