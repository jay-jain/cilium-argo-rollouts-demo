GATEWAY="$(kubectl get gateways.gateway.networking.k8s.io cilium -o=jsonpath="{.status.addresses[0].value}")"
for x in {1..100}; do curl -s -H "host: demo.example.com" ${GATEWAY}/callme >> curlresponses.txt ;done
version_one="$(cat curlresponses.txt| grep -c "1.0")"
version_two="$(cat curlresponses.txt| grep -c "2.0")"
echo -e "Responses from v1: ${version_one}"
echo -e "Responses from v2: ${version_two}"
rm curlresponses.txt