#!/bin/bash -e

set -eo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

function usage() {
    >&2 cat << EOF
Usage: ./gencerts.sh

Set the following environment variables to run this script:
    KUBECONFIG          The path to the kubeconfig file of the cluster.
                        
    BASE_DOMAIN         Base domain name of the cluster. For example if your API
                        server is running on "my-cluster-k8s.example.com", the
                        base domain is "example.com"
                        
    CLUSTER_NAME        Name of the cluster. If your API server is running on the
                        domain "my-cluster-k8s.example.com", the name of the cluster
                        is "my-cluster"
EOF
    exit 1
}

echo "Unzipping kubectl v1.9.0"
echo "y"| unzip ${DIR}/kubectl.zip 2> /dev/null
KUBECTL=${DIR}/kubectl

if [ -z $KUBECONFIG ]; then
    usage
fi

if [ -z $BASE_DOMAIN ]; then
    usage
fi

if [ -z $CLUSTER_NAME ]; then
    usage
fi

set -u

# On aws, api_endpoint = "//${CLUSTER_NAME}-api.${BASE_DOMAIN}"
# On bare-metal, api_endpoint = "//${CLUSTER_NAME}.${BASE_DOMAIN}"
untrimmed_api_endpoint=$(${KUBECTL} config view -ojson | jq -r '.clusters[0].cluster.server' | cut -d: -f 2)
export APISERVER_ENDPOINT=${untrimmed_api_endpoint:2}

export APISERVER_CLUSTER_IP=$(${KUBECTL} get services kubernetes -n default -o json | jq -r '.spec.clusterIP')
OLD_CA=$(${KUBECTL} get secret kube-apiserver -n kube-system -o json | jq -r '.data["ca.crt"]')
OLD_ETCD_CA=$(${KUBECTL} get secret kube-apiserver -n kube-system -o json | jq -r '.data["etcd-client-ca.crt"]')

export TARGET_DIR="generated"
if [ $# -eq 1 ]; then
    TARGET_DIR="$1"
fi

rm -fr ${TARGET_DIR}

export CERT_DIR=${TARGET_DIR}/tls
mkdir -p ${CERT_DIR}
PATCHES=${TARGET_DIR}/patches
mkdir -p $PATCHES
mkdir -p ${TARGET_DIR}/auth

# Configure expected OpenSSL CA configs.

touch $CERT_DIR/index
touch $CERT_DIR/index.txt
touch $CERT_DIR/index.txt.attr
echo 1000 > $CERT_DIR/serial
# Sign multiple certs for the same CN
echo "unique_subject = no" > $CERT_DIR/index.txt.attr

# Generate the openssl.conf
${DIR}/genopenssl.sh

function openssl_req() {
    openssl genrsa -out ${1}/${2}.key 2048
    echo "Generating ${1}/${2}.csr"
    openssl req -config openssl.conf -new -sha256 \
        -key ${1}/${2}.key -out ${1}/${2}.csr -subj "$3"
}

function openssl_sign() {
    echo "Generating ${3}/${4}.crt"
    openssl ca -batch -config openssl.conf -extensions ${5} -days 3650 -notext \
        -md sha256 -in ${3}/${4}.csr -out ${3}/${4}.crt \
        -cert ${1} -keyfile ${2}
}

function generate_ca() {
    openssl genrsa -out ${1}/ca.key 4096
    openssl req -config openssl.conf \
    -new -x509 -days 3650 -sha256 \
    -key ${1}/ca.key -extensions v3_ca \
    -out ${1}/ca.crt -subj "/CN=kube-ca/O=bootkube"
    export CA_KEY=${1}/ca.key
    export CA_CERT=${1}/ca.crt
}

generate_ca ${TARGET_DIR}/tls

# Generate CSRs for all components
openssl_req $CERT_DIR kubelet "/CN=kubelet/O=system:masters"
openssl_req $CERT_DIR apiserver "/CN=kube-apiserver/O=kube-master"
openssl_req $CERT_DIR ingress-server "/CN=${CLUSTER_NAME}.${BASE_DOMAIN}"
openssl_req $CERT_DIR identity-grpc-client "/CN=tectonic-identity-api.tectonic-system.svc.cluster.local"
openssl_req $CERT_DIR identity-grpc-server "/CN=tectonic-identity-api"

# Sign CSRs for all components
openssl_sign $CA_CERT $CA_KEY $CERT_DIR kubelet client_cert
openssl_sign $CA_CERT $CA_KEY $CERT_DIR apiserver apiserver_cert
openssl_sign $CA_CERT $CA_KEY $CERT_DIR ingress-server server_cert
openssl_sign $CA_CERT $CA_KEY $CERT_DIR identity-grpc-client client_cert
openssl_sign $CA_CERT $CA_KEY $CERT_DIR identity-grpc-server identity_server_cert

# Add debug information to directories
for CERT in $CERT_DIR/*.crt; do
    openssl x509 -in $CERT -noout -text > "${CERT%.crt}.txt"
done


# Generate a new etcd CA and associated certs.
ETCD_TLS=${TARGET_DIR}/tls/etcd
mkdir -p $ETCD_TLS
openssl genrsa -out $ETCD_TLS/ca.key 4096
openssl req -config openssl.conf \
    -new -x509 -days 3650 -sha256 \
    -key $ETCD_TLS/ca.key -extensions v3_ca \
    -out $ETCD_TLS/ca.crt -subj "/CN=etcd-ca"

openssl_req $ETCD_TLS peer "/CN=etcd"
openssl_req $ETCD_TLS server "/CN=etcd"
openssl_req $ETCD_TLS client "/CN=etcd"

openssl_sign $ETCD_TLS/ca.crt $ETCD_TLS/ca.key $ETCD_TLS peer etcd_peer_cert
openssl_sign $ETCD_TLS/ca.crt $ETCD_TLS/ca.key $ETCD_TLS server etcd_server_cert
openssl_sign $ETCD_TLS/ca.crt $ETCD_TLS/ca.key $ETCD_TLS client client_cert

# Add debug information to directories
for CERT in $ETCD_TLS/*.crt; do
    openssl x509 -in $CERT -noout -text > "${CERT%.crt}.txt"
done
rm $ETCD_TLS/*.csr

# Clean up openssl config
rm $CERT_DIR/index*
rm $CERT_DIR/100*
rm $CERT_DIR/serial*
rm $CERT_DIR/*.csr

# Generate patches

# 0. Create bundled CA certs and etcd patches.

echo ${OLD_CA} | base64 -d > ${CERT_DIR}/old_new_ca.crt
cat ${CERT_DIR}/ca.crt >> ${CERT_DIR}/old_new_ca.crt

echo ${OLD_ETCD_CA} | base64 -d > ${ETCD_TLS}/old_new_ca.crt
cat ${ETCD_TLS}/ca.crt >> ${ETCD_TLS}/old_new_ca.crt

PATCH_ETCD=$PATCHES/etcd
mkdir $PATCH_ETCD

cat > $PATCH_ETCD/etcd-bundle-ca.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  etcd-client-ca.crt: $( openssl base64 -A -in ${ETCD_TLS}/old_new_ca.crt )
EOF

cat > $PATCH_ETCD/etcd-ca.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  etcd-client-ca.crt: $( openssl base64 -A -in ${ETCD_TLS}/ca.crt )
EOF

cat > $PATCH_ETCD/etcd-client-cert.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  etcd-client.crt: $( openssl base64 -A -in ${ETCD_TLS}/client.crt )
  etcd-client.key: $( openssl base64 -A -in ${ETCD_TLS}/client.key )
EOF

# 1. Generate patches and kubeconfig that bundles the old and new ca.
PATCH_STEP_1=$PATCHES/step_1
mkdir $PATCH_STEP_1

cat > $PATCH_STEP_1/kube-apiserver-secret.patch <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  ca.crt: $( openssl base64 -A -in ${CERT_DIR}/old_new_ca.crt )
  oidc-ca.crt: $( openssl base64 -A -in ${CERT_DIR}/old_new_ca.crt )
EOF

cat > $PATCH_STEP_1/kube-controller-manager-secret.patch <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-controller-manager
  namespace: kube-system
data:
  ca.crt: $( openssl base64 -A -in ${CERT_DIR}/old_new_ca.crt )
EOF

cat > $PATCH_STEP_1/bundle_kubeconfig << EOF
apiVersion: v1
kind: Config
clusters:
- name: my-cluster
  cluster:
    server: https://${APISERVER_ENDPOINT}:443
    certificate-authority-data: $( openssl base64 -A -in ${CERT_DIR}/old_new_ca.crt ) 
users:
- name: kubelet
  user:
    client-certificate-data: $( openssl base64 -A -in $CERT_DIR/kubelet.crt ) 
    client-key-data: $( openssl base64 -A -in $CERT_DIR/kubelet.key ) 
contexts:
- context:
    cluster: my-cluster
    user: kubelet
EOF

cp $PATCH_STEP_1/bundle_kubeconfig ${TARGET_DIR}/auth/kubeconfig

# Also generate patches that updates CAs in the tectonic-system
cat > $PATCH_STEP_1/tectonic-ca-cert-secret.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: tectonic-ca-cert-secret
  namespace: tectonic-system
data:
  ca-cert: $( openssl base64 -A -in ${CERT_DIR}/ca.crt )
EOF

cat > $PATCH_STEP_1/ingress-tls.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: tectonic-ingress-tls-secret
  namespace: tectonic-system
data:
  tls.crt: $( openssl base64 -A -in ${CERT_DIR}/ingress-server.crt )
  tls.key: $( openssl base64 -A -in ${CERT_DIR}/ingress-server.key )
EOF

cat > $PATCH_STEP_1/identity-grpc-client.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: tectonic-identity-grpc-client-secret
  namespace: tectonic-system
data:
  ca-cert: $( openssl base64 -A -in ${CERT_DIR}/ca.crt )
  tls-cert: $( openssl base64 -A -in ${CERT_DIR}/identity-grpc-client.crt ) 
  tls-key: $( openssl base64 -A -in ${CERT_DIR}/identity-grpc-client.key )
EOF

cat > $PATCH_STEP_1/identity-grpc-server.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: tectonic-identity-grpc-server-secret
  namespace: tectonic-system
data:
  ca-cert: $( openssl base64 -A -in ${CERT_DIR}/ca.crt )
  tls-cert: $( openssl base64 -A -in ${CERT_DIR}/identity-grpc-server.crt )
  tls-key: $( openssl base64 -A -in ${CERT_DIR}/identity-grpc-server.key )
EOF

# 3. Generate patches that updates to the apiserver.crt
PATCH_STEP_2=$PATCHES/step_2
mkdir $PATCH_STEP_2

cat > $PATCH_STEP_2/kube-apiserver-secret.patch << EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  apiserver.crt: $( openssl base64 -A -in ${CERT_DIR}/apiserver.crt )
  apiserver.key: $( openssl base64 -A -in ${CERT_DIR}/apiserver.key )
  kubelet.crt: $( openssl base64 -A -in $CERT_DIR/kubelet.crt ) 
  kubelet.key: $( openssl base64 -A -in $CERT_DIR/kubelet.key )
EOF

# 4. Generate patches that deletes the old CA.
PATCH_STEP_3=$PATCHES/step_3
mkdir $PATCH_STEP_3

cat > $PATCH_STEP_3/kube-apiserver-secret.patch <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-apiserver
  namespace: kube-system
data:
  ca.crt: $( openssl base64 -A -in ${CERT_DIR}/ca.crt )
  oidc-ca.crt: $( openssl base64 -A -in ${CERT_DIR}/ca.crt )
EOF

cat > $PATCH_STEP_3/kube-controller-manager-secret.patch <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kube-controller-manager
  namespace: kube-system
data:
  ca.crt: $( openssl base64 -A -in ${CERT_DIR}/ca.crt )
EOF

cat > $PATCH_STEP_3/final_kubeconfig << EOF
apiVersion: v1
kind: Config
clusters:
- name: my-cluster
  cluster:
    server: https://${APISERVER_ENDPOINT}:443
    certificate-authority-data: $( openssl base64 -A -in ${CERT_DIR}/ca.crt ) 
users:
- name: kubelet
  user:
    client-certificate-data: $( openssl base64 -A -in $CERT_DIR/kubelet.crt ) 
    client-key-data: $( openssl base64 -A -in $CERT_DIR/kubelet.key ) 
contexts:
- context:
    cluster: my-cluster
    user: kubelet
EOF

echo ""
echo "certs and patches generated!"
echo ""
