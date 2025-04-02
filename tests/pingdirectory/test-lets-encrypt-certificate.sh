#!/bin/bash

set -e

echo "Test: Verify Let's Encrypt Certificate in PingDirectory Keystore and TrustStore"

# Export certificates from PingDirectory keystore and truststore
echo "Exporting PingDirectory keystore certificate..."
manage-certificates export-certificate --keystore config/keystore \
    --keystore-password-file config/keystore.pin \
    --alias server-cert \
    --output-file /opt/server-cert-keystore.crt \
    --output-format PEM --verbose

echo "Exporting PingDirectory truststore certificate..."
manage-certificates export-certificate --keystore config/truststore \
    --keystore-password-file config/truststore.pin \
    --alias server-cert \
    --output-file /opt/server-cert-truststore.crt \
    --output-format PEM --verbose

# Get the cluster cert (Let's Encrypt)
echo "Fetching Let's Encrypt certificate from Kubernetes secret..."
kubectl get secret acme-tls-cert -n ping-cloud \
    -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/cluster-certificate.crt

# Optional: Visual validation
echo "Cluster certificate details (optional):"
openssl crl2pkcs7 -nocrl -certfile /tmp/cluster-certificate.crt \
    | openssl pkcs7 -print_certs -text -noout

# Compare certs
echo "🔍 Comparing Cluster Cert with Keystore Cert..."
if cmp -s /tmp/cluster-certificate.crt /opt/server-cert-keystore.crt; then
    echo "Cluster cert matches Keystore cert"
else
    echo "Cluster cert DOES NOT match Keystore cert"
    exit 1
fi

echo "Comparing Cluster Cert with Truststore Cert..."
if cmp -s /tmp/cluster-certificate.crt /opt/server-cert-truststore.crt; then
    echo "Cluster cert matches Truststore cert"
else
    echo "Cluster cert DOES NOT match Truststore cert"
    exit 1
fi

echo "Test passed: Let's Encrypt cert matches both Keystore and Truststore certs"
