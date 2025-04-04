#!/bin/bash

set -e

echo "🔍 Test: Verify Let's Encrypt Certificate in PingDirectory Keystore and TrustStore"

NAMESPACE="ping-cloud"
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=pingdirectory-0 -o jsonpath="{.items[0].metadata.name}")

echo "Exporting keystore certificate from PingDirectory pod..."
kubectl exec -n $NAMESPACE $POD_NAME -- \
    manage-certificates export-certificate \
    --keystore config/keystore \
    --keystore-password-file config/keystore.pin \
    --alias server-cert \
    --output-file /tmp/server-cert-keystore.crt \
    --output-format PEM --verbose

kubectl cp $NAMESPACE/$POD_NAME:/tmp/server-cert-keystore.crt /opt/server-cert-keystore.crt

echo "Exporting truststore certificate from PingDirectory pod..."
kubectl exec -n $NAMESPACE $POD_NAME -- \
    manage-certificates export-certificate \
    --keystore config/truststore \
    --keystore-password-file config/truststore.pin \
    --alias server-cert \
    --output-file /tmp/server-cert-truststore.crt \
    --output-format PEM --verbose

kubectl cp $NAMESPACE/$POD_NAME:/tmp/server-cert-truststore.crt /opt/server-cert-truststore.crt

echo "🔐 Fetching Let's Encrypt certificate from Kubernetes secret..."
kubectl get secret acme-tls-cert -n $NAMESPACE \
    -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/cluster-certificate.crt

echo "📜 Cluster certificate details:"
openssl crl2pkcs7 -nocrl -certfile /tmp/cluster-certificate.crt \
    | openssl pkcs7 -print_certs -text -noout || true

echo "🧪 Comparing Cluster Cert with Keystore Cert..."
if cmp -s /tmp/cluster-certificate.crt /opt/server-cert-keystore.crt; then
    echo "Cluster cert matches Keystore cert"
else
    echo "Cluster cert DOES NOT match Keystore cert"
    exit 1
fi

echo "🧪 Comparing Cluster Cert with Truststore Cert..."
if cmp -s /tmp/cluster-certificate.crt /opt/server-cert-truststore.crt; then
    echo "Cluster cert matches Truststore cert"
else
    echo "Cluster cert DOES NOT match Truststore cert"
    exit 1
fi

echo "Test passed: Let's Encrypt cert matches both Keystore and Truststore certs"
