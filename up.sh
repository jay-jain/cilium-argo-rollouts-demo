#!/bin/bash

CILIUM_VERSION="v1.15.3"
ROLLOUTS_PLUGIN_VERSION="v0.2.0"
GATEWAY_API_VERSION="v1.0.0"
PLATFORM="linux-amd64"

# Make tmp dir
mkdir tmp/

# Create cluster with kind.yaml config file
kind create cluster --config kind.yaml

# Install Calico
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

# Install Gateway API
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/experimental/gateway.networking.k8s.io_grpcroutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml

sleep 15
# Install Cilium via helm
if ! helm repo list | grep -q cilium; then
	helm repo add cilium https://helm.cilium.io
fi
docker pull quay.io/cilium/cilium:${CILIUM_VERSION}
kind load docker-image quay.io/cilium/cilium:${CILIUM_VERSION} --name sm

helm upgrade \
	--install cilium cilium/cilium \
	--version ${CILIUM_VERSION} \
	--namespace kube-system \
	--reuse-values \
	--set-string kubeProxyReplacement=true \
	--set gatewayAPI.enabled=true \
	# --set ipam.mode=kubernetes \
	# --set externalIPs.enabled=true \
	# --set bpf.lbExternalClusterIP=true
	
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium

sleep 30

# Check if Cilium Gateway API enabled
cilium config view | grep "enable-gateway-api"
cilium config view | grep "enable-l7-proxy"

# Uninstall Calico
kubectl delete -f https://docs.projectcalico.org/manifests/calico.yaml

# Install and configure MetalLB
# Create the address pool
KIND_NET_CIDR=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}')
METALLB_IP_START=$(echo ${KIND_NET_CIDR} | sed "s@0.0/16@255.200@")
METALLB_IP_END=$(echo ${KIND_NET_CIDR} | sed "s@0.0/16@255.250@")
METALLB_IP_RANGE="${METALLB_IP_START}-${METALLB_IP_END}"

cat << EOF > tmp/metallb_values.yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
    name: default
    namespace: metallb-system
spec:
    addresses:
        - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
    name: default
    namespace: metallb-system
spec:
    ipAddressPools:
        - default
    nodeSelectors:
        - matchLabels:
              kubernetes.io/os: linux
EOF

# Install metallb 
helm install \
	--namespace metallb-system \
	--create-namespace \
	--repo https://metallb.github.io/metallb metallb \
	metallb \
	--version 0.13.10

sleep 60

kubectl -n metallb-system create -f tmp/metallb_values.yaml

sleep 30

# Validate Gateway Class exists
kubectl get gatewayclasses.gateway.networking.k8s.io

# Install Argo Rollouts (server)
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

sleep 30

# Install Argo Rollouts (client)
if ! command -v kubectl-argo-rollouts; then
	curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-${PLATFORM}
	chmod +x ./kubectl-argo-rollouts-${PLATFORM}
	mv ./kubectl-argo-rollouts-${PLATFORM} /usr/local/bin/kubectl-argo-rollouts
	kubectl argo rollouts version
fi

# Install Argo Rollouts plugin
cat << EOF > tmp/rollouts-plugin-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argo-rollouts-config # must be so name
  namespace: argo-rollouts # must be in this namespace
data:
  trafficRouterPlugins: |-
    - name: "argoproj-labs/gatewayAPI"
      location: "https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/${ROLLOUTS_PLUGIN_VERSION}/gateway-api-plugin-${PLATFORM}"
EOF
kubectl apply -f tmp/rollouts-plugin-cm.yaml
sleep 30
# Install RBAC
kubectl create -f argo-rollouts-rbac.yaml

# Restart Argo Rollouts 
kubectl -n argo-rollouts rollout restart deployment/argo-rollouts
sleep 30

# Deploy Gateway, HTTPRoute, Services, and Rollout
kubectl create -f rollouts-demo.yaml

sleep 45

# Test Gateway
GATEWAY="$(kubectl get gateways.gateway.networking.k8s.io cilium -o=jsonpath="{.status.addresses[0].value}")"
curl -s -H "host: demo.example.com" ${GATEWAY}/callme

echo -e "To view the Argo Rollouts dashboard and do a canary deployment, execute the following command: kubectl argo rollouts dashboard \n"

echo -e "Removing tmp/ dir \n" && rm -rf tmp/