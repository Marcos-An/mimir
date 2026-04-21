#!/usr/bin/env bash
set -euo pipefail

IDENTITY="Mimir Local Codesign"
KEYCHAIN_NAME="mimir-codesign.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"
KEYCHAIN_PASSWORD=""

if [ -f "$KEYCHAIN_PATH" ] && security find-certificate -c "$IDENTITY" "$KEYCHAIN_PATH" >/dev/null 2>&1; then
    echo "Identidade '$IDENTITY' já existe."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3

[dn]
CN = Mimir Local Codesign

[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
    -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -name "$IDENTITY" \
    -passout pass:mimir >/dev/null 2>&1

if [ ! -f "$KEYCHAIN_PATH" ]; then
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security set-keychain-settings "$KEYCHAIN_PATH"
fi

EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
if ! echo "$EXISTING" | grep -q "$KEYCHAIN_NAME"; then
    security list-keychains -d user -s $EXISTING "$KEYCHAIN_PATH"
fi

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

security import "$TMP/identity.p12" \
    -k "$KEYCHAIN_PATH" \
    -P mimir \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -A >/dev/null

security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:,unsigned:" \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

security add-trusted-cert \
    -r trustAsRoot \
    -p codeSign \
    -k "$KEYCHAIN_PATH" \
    "$TMP/cert.pem" >/dev/null 2>&1 || true

echo "Identidade '$IDENTITY' criada em $KEYCHAIN_PATH"
security find-identity -v -p codesigning "$KEYCHAIN_PATH" | head -5
