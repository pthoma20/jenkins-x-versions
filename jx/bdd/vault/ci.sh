#!/usr/bin/env bash
set -e
set -x

# setup environment
JX_HOME="/tmp/jxhome"
KUBECONFIG="/tmp/jxhome/config"

# lets avoid the git/credentials causing confusion during the test
export XDG_CONFIG_HOME=$JX_HOME
mkdir -p $JX_HOME/git

jx --version

export GH_USERNAME="jenkins-x-labs-bot"
export GH_EMAIL="jenkins-x@googlegroups.com"
# TODO when we can use an org and private repos
#export GH_OWNER="jenkins-x-labs-bdd-tests"
export GH_OWNER="jenkins-x-labs-bot"

export CLUSTER_NAME="${BRANCH_NAME,,}-$BUILD_NUMBER-bdd-vault"
export PROJECT_ID=jenkins-x-labs-bdd
export CREATED_TIME=$(date '+%a-%b-%d-%Y-%H-%M-%S')
export ZONE=europe-west1-c
export LABELS="branch=${BRANCH_NAME,,},cluster=bdd-vault,create-time=${CREATED_TIME,,}"

# lets setup git
git config --global --add user.name JenkinsXBot
git config --global --add user.email jenkins-x@googlegroups.com

echo "running the BDD test with JX_HOME = $JX_HOME"

# replace the credentials file with a single user entry
echo "https://$GH_USERNAME:$GH_ACCESS_TOKEN@github.com" > $JX_HOME/git/credentials

echo "creating cluster $CLUSTER_NAME in project $PROJECT_ID with labels $LABELS"

git clone https://github.com/jenkins-x-labs/cloud-resources.git
cloud-resources/gcloud/create_cluster.sh

# lets install vault
# Create a namespace for the vault operator
kubectl create namespace vault-infra
kubectl label namespace vault-infra name=vault-infra

# Install the vault-operator to the vault-infra namespace
helm repo add banzaicloud-stable https://kubernetes-charts.banzaicloud.com
helm upgrade --namespace vault-infra --install vault-operator banzaicloud-stable/vault-operator --wait

jxl ns jx

git clone https://github.com/jenkins-x-labs/bank-vaults

# Create a Vault instance
kubectl apply -f bank-vaults/operator/deploy/rbac.yaml
kubectl apply -f bank-vaults/operator/deploy/cr.yaml


# TODO remove once we remove the code from the multicluster branch of jx:
export JX_SECRETS_YAML=/tmp/secrets.yaml

echo "using the version stream ref: $PULL_PULL_SHA"

# create the boot git repository
jxl boot create -b --provider=gke --secret vault --version-stream-ref=$PULL_PULL_SHA --env-git-owner=$GH_OWNER --project=$PROJECT_ID --cluster=$CLUSTER_NAME --zone=$ZONE --out giturl.txt

# lets wait for the operator to kick in
sleep 60

# lets wait for the vault pod to be ready
kubectl wait  pod  -l app.kubernetes.io/name=vault --for=condition=Ready

# import secrets...
echo "secrets:
  adminUser:
    username: admin
    password: $JENKINS_PASSWORD
  hmacToken: $GH_ACCESS_TOKEN
  pipelineUser:
    username: $GH_USERNAME
    token: $GH_ACCESS_TOKEN
    email: $GH_EMAIL" > /tmp/secrets.yaml

# lets expose the vault service on localhost
kubectl port-forward service/vault 8200 &

sleep 5

export VAULT_ADDR=https://127.0.0.1:8200

jxl boot secrets import -f /tmp/secrets.yaml --git-url `cat giturl.txt`

# run the boot Job
echo running: jxl boot run -b --git-url `cat giturl.txt`

jxl boot run -b --job


# lets make sure jx defaults to helm3
export JX_HELM3="true"

gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE --project $PROJECT_ID
jx ns jx

# diagnostic commands to test the image's kubectl
kubectl version

# for some reason we need to use the full name once for the second command to work!
kubectl get environments
kubectl get env
kubectl get env dev -oyaml

# TODO not sure we need this?
helm init
helm repo add jenkins-x https://storage.googleapis.com/chartmuseum.jenkins-x.io


export JX_DISABLE_DELETE_APP="true"

export GIT_ORGANISATION="$GH_OWNER"


# run the BDD tests
bddjx -ginkgo.focus=golang -test.v
