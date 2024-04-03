# cilium-argo-rollouts-demo

This project demonstrates using Cilium and Argo Rollouts using the Gateway API.

To get started, execute the `up.sh` script, which does the following:

- Bootstraps a kind cluster
- Temporarily installs calico CNI to bring the cluster into a ready state
- Installs Gateway API
- Installs Cilium with required flags
- Installs MetalLB for L2 traffic
- Installs argo-rollouts
- Installs Argo Rollouts plugin for Cilium
- Deploys the following:
  - `Gateway`
  - 2 `Service` objects (1 for stable, 1 for canary)
  - `HTTPRoute` object
  - `Rollout` object

```sh
$ k get svc
NAME                           TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
argo-rollouts-canary-service   ClusterIP      10.96.187.25    <none>           80/TCP         67s
argo-rollouts-stable-service   ClusterIP      10.96.234.23    <none>           80/TCP         67s
cilium-gateway-cilium          LoadBalancer   10.96.115.242   172.18.255.200   80:30188/TCP   68s
kubernetes                     ClusterIP      10.96.0.1       <none>           443/TCP        6m43s
```

You can execute the `./test_canary.sh` script to see which % of requests are going to which version of the application. You can run this
step every time after you do a canary promotion:

```sh
$ ./test_canary.sh
Responses from v1: 0
Responses from v2: 100
```

To execute a canary, you can do this from Argo Rollouts UI:

```sh
kubectl argo rollouts dashboard
```

## Requirements

-   kubectl
-   helm
-   kind `v0.22.0`
-   argo-rollouts CLI

## Cilium L2 Announcements

Cilium offers L2 announcements which can be used instead of MetalLB. There would need to be a couple of modifications to the installation
though:

-   The Helm installation of Cilium would need different flags as such:

```sh
helm install cilium cilium/cilium --version ${CILIUM_VERSION} \
   --namespace kube-system \
   --set image.pullPolicy=IfNotPresent \
   --set-string kubeProxyReplacement=true \
   --set gatewayAPI.enabled=true \
   --set l2podAnnouncements.enabled=true \
   --set l2podAnnouncements.interface=eth0 \
   --set l2announcements.enabled=true \
   --set k8sServiceHost=172.16.0.1 \
   --set k8sServicePort=443
```

-   Create an IP pool and announcement policy

```yml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
    name: "blue-pool"
spec:
    cidrs:
        - cidr: "172.18.255.200/29"
        - cidr: "172.18.255.208/28"
        - cidr: "172.18.255.224/28"
        - cidr: "172.18.255.240/29"
        - cidr: "172.18.255.248/31"
        - cidr: "172.18.255.250/32"
---
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
    name: policy1
spec:
    externalIPs: true
    loadBalancerIPs: true
```

## Hubble

You can use `hubble` to debug and view network traffic within a Cilium-enabled cluster:

```sh
# hubble
cilium hubble enable
cilium status

# install hubble client
if ! command -v hubble; then
   HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
   HUBBLE_ARCH=amd64
   if [ "$(uname -m)" = "aarch64" ]; then HUBBLE_ARCH=arm64; fi
   curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}
   sha256sum --check hubble-linux-${HUBBLE_ARCH}.tar.gz.sha256sum
   sudo tar xzvfC hubble-linux-${HUBBLE_ARCH}.tar.gz /usr/local/bin
   rm hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}
fi

# Verify hubble api access
cilium hubble port-forward&
hubble status
hubble observe

# Enable Hubble UI
cilium hubble enable --ui
cilium hubble ui

```

## References

-   https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/tree/main/examples/cilium
-   https://rollouts-plugin-trafficrouter-gatewayapi.readthedocs.io/en/latest/installation/
-   https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/
