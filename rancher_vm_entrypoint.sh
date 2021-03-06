#!/bin/bash -x
#
# Copyright 2018 Huawei Technologies Co., Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#

printenv

mkdir -p /opt/config
echo "__rancher_ip_addr__" > /opt/config/rancher_ip_addr.txt
echo "__k8s_vm_ips__" > /opt/config/k8s_vm_ips.txt
echo "__k8s_private_ips__" > /opt/config/k8s_private_ips.txt
echo "__public_net_id__" > /opt/config/public_net_id.txt
echo "__oam_network_cidr__" > /opt/config/oam_network_cidr.txt
echo "__oam_network_id__" > /opt/config/oam_network_id.txt
echo "__oam_subnet_id__" > /opt/config/oam_subnet_id.txt
echo "__integration_gerrit_branch__" > /opt/config/integration_gerrit_branch.txt
echo "__integration_gerrit_refspec__" > /opt/config/integration_gerrit_refspec.txt
echo "__oom_gerrit_branch__" > /opt/config/oom_gerrit_branch.txt
echo "__oom_gerrit_refspec__" > /opt/config/oom_gerrit_refspec.txt
echo "__docker_manifest__" > /opt/config/docker_manifest.txt
echo "__docker_proxy__" > /opt/config/docker_proxy.txt
echo "__docker_version__" > /opt/config/docker_version.txt
echo "__rancher_version__" > /opt/config/rancher_version.txt
echo "__rancher_agent_version__" > /opt/config/rancher_agent_version.txt
echo "__kubectl_version__" > /opt/config/kubectl_version.txt
echo "__helm_version__" > /opt/config/helm_version.txt

cat <<EOF > /opt/config/integration-override.yaml
__integration_override_yaml__
EOF
sed -i 's/\_\_public_net_id__/__public_net_id__/g' /opt/config/integration-override.yaml
sed -i 's|\_\_oam_network_cidr__|__oam_network_cidr__|g' /opt/config/integration-override.yaml
sed -i 's/\_\_oam_network_id__/__oam_network_id__/g' /opt/config/integration-override.yaml
sed -i 's/\_\_oam_subnet_id__/__oam_subnet_id__/g' /opt/config/integration-override.yaml
sed -i 's/\_\_rancher_ip_addr__/__rancher_ip_addr__/g' /opt/config/integration-override.yaml
sed -i 's/\_\_k8s_1_vm_ip__/__k8s_1_vm_ip__/g' /opt/config/integration-override.yaml
sed -i 's/\_\_docker_proxy__/__docker_proxy__/g' /opt/config/integration-override.yaml
cp /opt/config/integration-override.yaml /root
cat /root/integration-override.yaml

echo `hostname -I` `hostname` >> /etc/hosts
mkdir -p /etc/docker
if [ ! -z "__docker_proxy__" ]; then
    cat > /etc/docker/daemon.json <<EOF
{
  "insecure-registries" : ["__docker_proxy__"]
}
EOF
fi
if [ ! -z "__apt_proxy__" ]; then
    cat > /etc/apt/apt.conf.d/30proxy<<EOF
Acquire::http { Proxy "http://__apt_proxy__"; };
Acquire::https::Proxy "DIRECT";
EOF
fi

while ! hash jq &> /dev/null; do
    apt-get -y update
    apt-get -y install linux-image-extra-$(uname -r) apt-transport-https ca-certificates curl software-properties-common jq make nfs-kernel-server moreutils
    sleep 10
done

# use RAM disk for /dockerdata-nfs for testing
echo "tmpfs /dockerdata-nfs tmpfs noatime,size=75% 1 2" >> /etc/fstab
mkdir -pv /dockerdata-nfs
mount /dockerdata-nfs

# version control the persistence volume to see what's happening
chmod 777 /dockerdata-nfs/
chown nobody:nogroup /dockerdata-nfs/
cd /dockerdata-nfs/
git init
git config user.email "root@onap"
git config user.name "root"
git add -A
git commit -m "initial commit"

# export NFS mount
echo "/dockerdata-nfs *(rw,fsid=1,async,no_root_squash,no_subtree_check)" | tee /etc/exports


exportfs -a
systemctl restart nfs-kernel-server

cd ~

# install docker __docker_version__
while ! hash docker &> /dev/null; do
    curl -s https://releases.rancher.com/install-docker/__docker_version__.sh | sh
    usermod -aG docker ubuntu
    sleep 10
done
apt-mark hold docker-ce

# install rancher __rancher_version__
docker run --name rancher-server --restart unless-stopped -d -p 8080:8080 -e CATTLE_BOOTSTRAP_REQUIRED_IMAGE=__docker_proxy__/rancher/agent:v__rancher_agent_version__ __docker_proxy__/rancher/server:v__rancher_version__

# install kubectl __kubectl_version__
curl -s -LO https://storage.googleapis.com/kubernetes-release/release/v__kubectl_version__/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
mkdir ~/.kube

# install helm __helm_version__
wget -q http://storage.googleapis.com/kubernetes-helm/helm-v__helm_version__-linux-amd64.tar.gz
tar -zxvf helm-v__helm_version__-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm

echo export RANCHER_IP=__rancher_private_ip_addr__ > api-keys-rc
source api-keys-rc

until curl -s -o projects.json -H "Accept: application/json" http://$RANCHER_IP:8080/v2-beta/projects; do
    sleep 30
done
OLD_PID=$(jq -r '.data[0].id' projects.json)

curl -s -H "Accept: application/json" -H "Content-Type: application/json" -d '{"accountId":"1a1"}' http://$RANCHER_IP:8080/v2-beta/apikeys > apikeys.json
echo export CATTLE_ACCESS_KEY=`jq -r '.publicValue' apikeys.json` >> api-keys-rc
echo export CATTLE_SECRET_KEY=`jq -r '.secretValue' apikeys.json` >> api-keys-rc
source api-keys-rc


curl -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{"id":"registry.default","type":"activeSetting","baseType":"setting","name":"registry.default","activeValue":"__docker_proxy__","inDb":true,"source":"Database","value":"__docker_proxy__"}'  http://$RANCHER_IP:8080/v2-beta/settings/registry.default

curl -s -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" -X DELETE -H 'Content-Type: application/json' "http://$RANCHER_IP:8080/v2-beta/projects/$OLD_PID"

until [ ! -z "$TEMPLATE_ID" ] && [ "$TEMPLATE_ID" != "null" ]; do
    sleep 5
    curl -s -H "Accept: application/json" http://$RANCHER_IP:8080/v2-beta/projectTemplates?name=Kubernetes > projectTemplatesKubernetes.json
    TEMPLATE_ID=$(jq -r '.data[0].id' projectTemplatesKubernetes.json)
done


# rancher 1.6.18 k8s templateVersionIds
#   v1.8.10-rancher1-1: library:infra*k8s:43
#   v1.9.5-rancher1-3: library:infra*k8s:46
#   v1.10.3-rancher1-1: library:infra*k8s:47

# rancher 1.6.22 k8s templateVersionIds
#   v1.11.2-rancher1-2: library:infra*k8s:52

curl -s -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" \
-X PUT \
-H 'Accept: application/json' \
-H 'Content-Type: application/json' \
-d '{"stacks":[{"type":"catalogTemplate", "answers":{"CONSTRAINT_TYPE":"required"}, "name":"kubernetes", "templateVersionId":"library:infra*k8s:52"}, {"type":"catalogTemplate", "name":"network-services", "templateId":"library:infra*network-services"}, {"type":"catalogTemplate", "name":"ipsec", "templateId":"library:infra*ipsec"}, {"type":"catalogTemplate", "name":"healthcheck", "templateId":"library:infra*healthcheck"}]}' \
"http://$RANCHER_IP:8080/v2-beta/projecttemplates/$TEMPLATE_ID"


curl -s -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" -X POST -H 'Content-Type: application/json' -d '{ "name":"oom", "projectTemplateId":"'$TEMPLATE_ID'" }' "http://$RANCHER_IP:8080/v2-beta/projects" > project.json
PID=`jq -r '.id' project.json`
echo export RANCHER_URL=http://$RANCHER_IP:8080/v1/projects/$PID >> api-keys-rc
source api-keys-rc

until [ $(jq -r '.state' project.json) == "active" ]; do
    sleep 5
    curl -s -H "Accept: application/json" http://$RANCHER_IP:8080/v1/projects/$PID > project.json
done


curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -X POST -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{"name":"docker-proxy", "serverAddress":"__docker_proxy__"}' $RANCHER_URL/registries > registry.json
RID=$(jq -r '.id' registry.json)


curl -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" -X POST -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{"publicValue":"docker", "registryId":"'$RID'", "secretValue":"docker", "type":"registryCredential"}' "http://$RANCHER_IP:8080/v2-beta/projects/$PID/registrycredential"



TID=$(curl -s -X POST -H "Accept: application/json" -H "Content-Type: application/json" http://$RANCHER_IP:8080/v1/projects/$PID/registrationTokens | jq -r '.id')
touch token.json
while [ $(jq -r .command token.json | wc -c) -lt 10 ]; do
    sleep 5
    curl -s -X GET -H "Accept: application/json" http://$RANCHER_IP:8080/v1/projects/$PID/registrationToken/$TID > token.json
done
jq -r .command token.json > rancher_agent_cmd.sh
chmod +x rancher_agent_cmd.sh
cp rancher_agent_cmd.sh /dockerdata-nfs
cd /dockerdata-nfs
git add -A
git commit -a -m "Add rancher agent command file"
cd ~


KUBETOKEN=$(echo -n 'Basic '$(echo -n "$CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY" | base64 -w 0) | base64 -w 0)

# create .kube/config
cat > ~/.kube/config <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    api-version: v1
    insecure-skip-tls-verify: true
    server: "https://__rancher_ip_addr__:8080/r/projects/$PID/kubernetes:6443"
  name: "oom"
contexts:
- context:
    cluster: "oom"
    user: "oom"
  name: "oom"
current-context: "oom"
users:
- name: "oom"
  user:
    token: "$KUBETOKEN"
EOF

export KUBECONFIG=/root/.kube/config
kubectl config view

# Enable auto-completion for kubectl
echo "source <(kubectl completion bash)" >> ~/.bashrc


# wait for kubernetes to initialze
sleep 3m
until [ $(kubectl get pods --namespace kube-system | tail -n +2 | grep -c Running) -ge 6 ]; do
    sleep 1m
done

