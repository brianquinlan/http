# Test certificates

These certificates are only used by the tests. They were generated with:

```shell
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout ca_key.pem -out ca.pem \
  -days 36500 -subj "/CN=curl_http test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -sha256 -keyout server_key.pem \
  -out server.csr -subj "/CN=localhost"
printf "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > ext.cnf
openssl x509 -req -sha256 -in server.csr -CA ca.pem -CAkey ca_key.pem \
  -CAcreateserial -out server.pem -days 36500 -extfile ext.cnf
```

The private key of the certificate authority was discarded.
