#!/usr/bin/env bash
set -e

echo "Regenerating certificates…"

CERT_DIR=/etc/ssl/certs
KEY_DIR=/etc/ssl/private
CONFIG_DIR=/etc/lamassu

LAMASSU_CA_PATH=$CERT_DIR/Lamassu_CA.pem
CA_KEY_PATH=$KEY_DIR/Lamassu_OP_Root_CA.key
CA_PATH=$CERT_DIR/Lamassu_OP_Root_CA.pem
SERVER_KEY_PATH=$KEY_DIR/Lamassu_OP.key
SERVER_CERT_PATH=$CERT_DIR/Lamassu_OP.pem

IP=$(hostname -I | awk '{print $1}')

echo "Using IP: $IP"
echo

# ---- Generate new Root CA key ----
openssl genrsa \
  -out "$CA_KEY_PATH" \
  4096

# ---- Generate Root CA certificate ----
openssl req \
  -x509 \
  -sha256 \
  -new \
  -nodes \
  -key "$CA_KEY_PATH" \
  -days 3650 \
  -out "$CA_PATH" \
  -subj "/C=IS/ST=/L=Reykjavik/O=Lamassu Operator CA/CN=operator.lamassu.is"

# ---- Generate server key ----
openssl genrsa \
  -out "$SERVER_KEY_PATH" \
  4096

# ---- Generate CSR with SAN ----
openssl req -new \
  -key "$SERVER_KEY_PATH" \
  -out /tmp/Lamassu_OP.csr.pem \
  -subj "/C=IS/ST=/L=Reykjavik/O=Lamassu Operator/CN=$IP" \
  -reqexts SAN \
  -sha256 \
  -config <(cat /etc/ssl/openssl.cnf \
      <(printf "[SAN]\nsubjectAltName=IP.1:$IP"))

# ---- Sign server certificate with CA ----
openssl x509 \
  -req -in /tmp/Lamassu_OP.csr.pem \
  -CA "$CA_PATH" \
  -CAkey "$CA_KEY_PATH" \
  -CAcreateserial \
  -out "$SERVER_CERT_PATH" \
  -extfile <(cat /etc/ssl/openssl.cnf \
      <(printf "[SAN]\nsubjectAltName=IP.1:$IP")) \
  -extensions SAN \
  -days 3650

rm /tmp/Lamassu_OP.csr.pem

echo
echo "Done!"
echo "Restarting Lamassu services…"
supervisorctl restart lamassu-server lamassu-admin-server

echo
echo "New certificates installed successfully."
echo "All done!"
echo "  $CA_PATH"
