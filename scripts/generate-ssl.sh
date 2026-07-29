#!/usr/bin/env bash

# Generate a self-signed wildcard SSL certificate for *.dev.local, valid for any
# subdomain: app.dev.local, api.dev.local, and so on.
#
# Generating it is identical everywhere - openssl is openssl. Trusting it is not,
# so the instructions at the end come from platforms/<os>.sh. They are printed
# rather than run: adding a root certificate is a decision to make with your eyes
# open, and on half these platforms it needs a privilege this script doesn't have.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
SSL_DIR="${INFRA_DIR}/ssl"
DOMAIN="dev.local"

. "${INFRA_DIR}/platforms/platform.sh"

infra_require_command openssl || exit 1

mkdir -p "$SSL_DIR"

infra_info "Generating wildcard SSL certificate for *.${DOMAIN}..."
echo ""

# Generate CA key and certificate
openssl genrsa -out "$SSL_DIR/ca.key" 4096

openssl req -x509 -new -nodes \
    -key "$SSL_DIR/ca.key" \
    -sha256 -days 3650 \
    -out "$SSL_DIR/ca.crt" \
    -subj "/C=US/ST=Dev/L=Local/O=DevLocal/CN=Dev Local CA"

# Create config for wildcard certificate
cat > "$SSL_DIR/wildcard.cnf" << EOF
[req]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = req_ext
x509_extensions = v3_ca

[req_distinguished_name]
countryName = Country Name
stateOrProvinceName = State
localityName = City
organizationName = Organization
commonName = Common Name

[req_ext]
subjectAltName = @alt_names

[v3_ca]
subjectAltName = @alt_names
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment

[alt_names]
DNS.1 = *.${DOMAIN}
DNS.2 = ${DOMAIN}
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

# Generate wildcard certificate key and CSR
openssl genrsa -out "$SSL_DIR/wildcard.key" 2048

openssl req -new \
    -key "$SSL_DIR/wildcard.key" \
    -out "$SSL_DIR/wildcard.csr" \
    -subj "/C=US/ST=Dev/L=Local/O=DevLocal/CN=*.${DOMAIN}" \
    -config "$SSL_DIR/wildcard.cnf"

# Sign the certificate with our CA
openssl x509 -req \
    -in "$SSL_DIR/wildcard.csr" \
    -CA "$SSL_DIR/ca.crt" \
    -CAkey "$SSL_DIR/ca.key" \
    -CAcreateserial \
    -out "$SSL_DIR/wildcard.crt" \
    -days 3650 \
    -sha256 \
    -extensions v3_ca \
    -extfile "$SSL_DIR/wildcard.cnf"

# A no-op on a Windows filesystem, which has no mode bits to set - harmless
# there, and it keeps the key unreadable everywhere that does.
chmod 600 "$SSL_DIR"/*.key
chmod 644 "$SSL_DIR"/*.crt

infra_banner "SSL certificates generated" "$INFRA_GREEN"
echo "Files created in: $SSL_DIR"
echo "  - ca.crt          (CA certificate - trust this one)"
echo "  - ca.key          (CA private key)"
echo "  - wildcard.crt    (Wildcard certificate for *.${DOMAIN})"
echo "  - wildcard.key    (Wildcard private key)"

infra_banner "Trust the CA on $(platform_label)"
platform_trust_ca "${SSL_DIR}/ca.crt"
echo ""
infra_firefox_note
echo ""
