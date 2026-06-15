# Trusting the gateway TLS cert on client machines

The SEHC AI Gateway serves HTTPS on `:8443` with a **self-signed** certificate
(SAN = the gateway's IP). To call it over HTTPS without `-k` / "allow self-signed",
trust the cert once per client machine.

## 1. Get the cert from the gateway (on PCA)
```bash
sudo cat /opt/kong/ssl/kong-proxy.crt          # copy the PEM block
# or:  scp user@<PCA_IP>:/opt/kong/ssl/kong-proxy.crt .
```
Confirm which IP it is for (clients must connect by that IP):
```bash
openssl x509 -in kong-proxy.crt -noout -ext subjectAltName    # IP Address:<PCA_IP>
```

## 2. Trust it on the client

**Linux** (Debian/Ubuntu or RHEL/Fedora):
```bash
sudo ./trust-kong-cert.sh kong-proxy.crt
```

**Windows** (elevated PowerShell):
```powershell
powershell -ExecutionPolicy Bypass -File .\trust-kong-cert.ps1 -CertPath .\kong-proxy.crt
```

## 3. Test
```bash
curl https://<PCA_IP>:8443/        # no -k needed; TLS verifies cleanly
```

> Don't want to trust system-wide? Skip these scripts and just point the client at
> the cert per-request: `curl --cacert kong-proxy.crt ...`,
> Python `verify="kong-proxy.crt"`, Node `NODE_EXTRA_CA_CERTS=kong-proxy.crt`,
> or in n8n enable "Allow Self-Signed Certificates".
