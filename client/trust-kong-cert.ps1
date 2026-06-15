<#
  trust-kong-cert.ps1 — trust the SEHC AI Gateway self-signed proxy cert on a
  Windows CLIENT, so HTTPS to the gateway (:8443) works without ignoring cert
  errors. Imports the cert into "Trusted Root Certification Authorities".

  1. Copy kong-proxy.crt from the gateway (/opt/kong/ssl/kong-proxy.crt) next to
     this script.
  2. Open PowerShell *as Administrator* and run:
        powershell -ExecutionPolicy Bypass -File .\trust-kong-cert.ps1
     or specify the path:
        powershell -ExecutionPolicy Bypass -File .\trust-kong-cert.ps1 -CertPath C:\path\kong-proxy.crt
#>
param(
  [string]$CertPath = (Join-Path $PSScriptRoot 'kong-proxy.crt')
)

$ErrorActionPreference = 'Stop'

# Require elevation (writing to LocalMachine store).
$admin = ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent() `
         ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) { Write-Error 'Run this in an elevated (Administrator) PowerShell.'; exit 1 }

if (-not (Test-Path $CertPath)) { Write-Error "Certificate not found: $CertPath"; exit 1 }

$cert = Import-Certificate -FilePath $CertPath -CertStoreLocation 'Cert:\LocalMachine\Root'

Write-Host '[OK] Imported into Trusted Root Certification Authorities (LocalMachine\Root).'
Write-Host ("     Subject: {0}" -f $cert.Subject)
Write-Host ("     SAN:     {0}" -f (($cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Subject Alternative Name' }).Format($false)))
Write-Host '     Test:    curl.exe https://<PCA_IP>:8443/   (no cert error now)'
