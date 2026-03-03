#!/bin/bash
set -e

CERTBOT_LOG=/var/log/letsencrypt/letsencrypt.log

# On any failure, dump the certbot log if it exists so the cause is visible
trap 'if [ -f "$CERTBOT_LOG" ]; then echo "--- certbot log ---"; cat "$CERTBOT_LOG"; fi' ERR

# 1. Fetch the Anycast IP from BunnyCDN and update the DNS A record.
# Requires: BUNNY_APIKEY, BUNNY_APP_ID, BUNNY_ZONEID, BUNNY_RECORDID, DNS_SUBDOMAIN
if [ -n "$BUNNY_APIKEY" ] && [ -n "$BUNNY_APP_ID" ] && [ -n "$BUNNY_ZONEID" ] && [ -n "$BUNNY_RECORDID" ] && [ -n "$DNS_SUBDOMAIN" ]; then
    ANYCAST_IP=$(curl -sf \
        --header "AccessKey: ${BUNNY_APIKEY}" \
        "https://api.bunny.net/mc/apps/${BUNNY_APP_ID}/endpoints" | \
        jq -r '[.items[] | select(.type == "Anycast") | .publicIpAddresses[0].address] | first')

    if [ -z "$ANYCAST_IP" ] || [ "$ANYCAST_IP" = "null" ]; then
        echo "WARNING: could not determine Anycast IP, skipping DNS update"
    else
        echo "Updating DNS: ${DNS_SUBDOMAIN} -> ${ANYCAST_IP}"
        curl -sf --request POST \
            --url "https://api.bunny.net/dnszone/${BUNNY_ZONEID}/records/${BUNNY_RECORDID}" \
            --header "AccessKey: ${BUNNY_APIKEY}" \
            --header 'Content-Type: application/json' \
            --data "{
                \"Type\": 0,
                \"Ttl\": 120,
                \"Value\": \"${ANYCAST_IP}\",
                \"Name\": \"${DNS_SUBDOMAIN}\",
                \"Weight\": 100,
                \"Priority\": 0
            }"
        echo "DNS updated."
    fi
fi

# Obtain/renew TLS certificate via certbot standalone HTTP challenge.
# Requires port 80 to be open and the domain's A record to already point at this host.
if [ -n "$CERTBOT_DOMAIN" ] && [ -n "$CERTBOT_EMAIL" ]; then
    CERT_DIR="/run/letsencrypt"

    certbot certonly \
        --standalone \
        --config-dir "$CERT_DIR" \
        ${CERTBOT_STAGING:+--staging -vvv} \
        -d "$CERTBOT_DOMAIN" \
        --email "$CERTBOT_EMAIL" \
        --non-interactive --agree-tos \
        --keep-until-expiring

    CERT="${CERT_DIR}/live/${CERTBOT_DOMAIN}/fullchain.pem"
    KEY="${CERT_DIR}/live/${CERTBOT_DOMAIN}/privkey.pem"

    if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
        echo "ERROR: cert files not found after certbot:"
        echo "  cert: $CERT"
        echo "  key:  $KEY"
        ls -la "${CERT_DIR}/live/" 2>/dev/null || echo "  (live/ dir does not exist)"
        exit 1
    fi

    echo "Cert: $CERT"
    echo "Key:  $KEY"

    export MOQ_SERVER_TLS_CERT="$CERT"
    export MOQ_SERVER_TLS_KEY="$KEY"
    export MOQ_WEB_HTTPS_CERT="$CERT"
    export MOQ_WEB_HTTPS_KEY="$KEY"
fi

echo "Starting moq-relay..."
exec /usr/local/bin/moq-relay "$@"
