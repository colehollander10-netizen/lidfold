#!/usr/bin/env bash
# Creates a self-signed code signing identity named "Lidfold Local Signing" in
# the login keychain, so every build of Lidfold carries the same identity and
# macOS keeps the Screen Recording grant across rebuilds. Run once per Mac.
set -euo pipefail
NAME="Lidfold Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists"; exit 0
fi
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
cat > "$D/ext.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
subjectKeyIdentifier=hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$D/key.pem" -out "$D/cert.pem" -config "$D/ext.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -out "$D/id.p12" -inkey "$D/key.pem" -in "$D/cert.pem" -passout pass:lidfold 2>/dev/null \
  || openssl pkcs12 -export -out "$D/id.p12" -inkey "$D/key.pem" -in "$D/cert.pem" -passout pass:lidfold
security import "$D/id.p12" -k ~/Library/Keychains/login.keychain-db -P lidfold -T /usr/bin/codesign -T /usr/bin/security
echo "created \"$NAME\"; ./build.sh will use it automatically"
