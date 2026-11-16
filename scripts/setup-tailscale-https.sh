#!/bin/bash
# Configure Tailscale HTTPS for spark-realtime-chatbot on DGX Spark.
#
# Supports two sub-modes:
#   1. serve (default, recommended):
#      Configures `tailscale serve` to reverse-proxy https://<spark>.<tailnet>.ts.net
#      to http://127.0.0.1:${PORT:-8443} with an automatically renewed Let's Encrypt certificate.
#   2. cert (--cert):
#      Uses `tailscale cert` to provision cert.pem and key.pem directly for uvicorn.

set -euo pipefail

PORT="${PORT:-8443}"
MODE="serve"
SSL_CERT="${SSL_CERT:-cert.pem}"
SSL_KEY="${SSL_KEY:-key.pem}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --serve)
            MODE="serve"
            shift
            ;;
        --cert)
            MODE="cert"
            shift
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --ssl-cert)
            SSL_CERT="$2"
            shift 2
            ;;
        --ssl-key)
            SSL_KEY="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--serve | --cert] [--port PORT] [--ssl-cert PATH] [--ssl-key PATH]"
            echo ""
            echo "Options:"
            echo "  --serve          Configure 'tailscale serve' reverse proxy to http://127.0.0.1:PORT (default)"
            echo "  --cert           Fetch TLS certificate/key via 'tailscale cert' for direct uvicorn TLS"
            echo "  --port PORT      Local port the chatbot listens on (default: 8443)"
            echo "  --ssl-cert PATH  Output certificate path for --cert mode (default: cert.pem)"
            echo "  --ssl-key PATH   Output private key path for --cert mode (default: key.pem)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if ! command -v tailscale >/dev/null 2>&1; then
    echo "ERROR: 'tailscale' CLI is not installed."
    echo "Install Tailscale on DGX Spark:"
    echo "  curl -fsSL https://tailscale.com/install.sh | sh"
    echo "  sudo tailscale up"
    exit 1
fi

# Resolve the machine's MagicDNS FQDN (e.g. spark.tailnet-name.ts.net)
TS_DNS_NAME=""
if command -v python3 >/dev/null 2>&1; then
    TS_DNS_NAME=$(tailscale status --json 2>/dev/null | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('Self', {}).get('DNSName', '').rstrip('.'))" 2>/dev/null || true)
fi

if [ -z "$TS_DNS_NAME" ]; then
    TS_DNS_NAME=$(tailscale cert 2>&1 | grep -oE '[a-zA-Z0-9._-]+\.ts\.net' | head -n 1 || true)
fi

if [ -z "$TS_DNS_NAME" ]; then
    echo "ERROR: Could not determine Tailscale MagicDNS hostname."
    echo "Make sure Tailscale is connected ('sudo tailscale up') and MagicDNS + HTTPS"
    echo "certificates are enabled in the Tailscale admin console (https://login.tailscale.com/admin/dns)."
    exit 1
fi

if [ "$MODE" = "serve" ]; then
    echo "=========================================="
    echo "Configuring Tailscale Serve (HTTPS)"
    echo "=========================================="
    echo "Tailscale domain : https://${TS_DNS_NAME}"
    echo "Backend target   : http://127.0.0.1:${PORT}"
    echo ""

    if ! tailscale serve --bg "http://127.0.0.1:${PORT}" 2>/dev/null; then
        sudo tailscale serve --bg "http://127.0.0.1:${PORT}"
    fi

    echo ""
    echo "✅ Tailscale Serve is active!"
    echo ""
    echo "Start the app bound to plain HTTP on 127.0.0.1:"
    echo "  HOST=127.0.0.1 PORT=${PORT} SSL_ENABLED=false ./launch-https.sh --local-asr --tts-overlap"
    echo "  (or: ./launch-https.sh --tailscale-serve --local-asr --tts-overlap)"
    echo ""
    echo "Then open on your Mac or phone (connected to Tailscale):"
    echo "  https://${TS_DNS_NAME}"
else
    echo "=========================================="
    echo "Provisioning Tailscale TLS Certificate"
    echo "=========================================="
    echo "Tailscale domain : ${TS_DNS_NAME}"
    echo "Cert file        : ${SSL_CERT}"
    echo "Key file         : ${SSL_KEY}"
    echo ""

    if ! tailscale cert --cert-file "$SSL_CERT" --key-file "$SSL_KEY" "$TS_DNS_NAME" 2>/dev/null; then
        sudo tailscale cert --cert-file "$SSL_CERT" --key-file "$SSL_KEY" "$TS_DNS_NAME"
        sudo chown "$(id -u):$(id -g)" "$SSL_CERT" "$SSL_KEY"
    fi

    echo ""
    echo "✅ Certificate provisioned: $SSL_CERT, $SSL_KEY"
    echo ""
    echo "Start the app with:"
    echo "  SSL_CERT=${SSL_CERT} SSL_KEY=${SSL_KEY} ./launch-https.sh --local-asr --tts-overlap"
    echo ""
    echo "Then open on your Mac or phone (connected to Tailscale):"
    echo "  https://${TS_DNS_NAME}:${PORT}"
fi
