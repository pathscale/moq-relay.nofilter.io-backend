#!/bin/bash
set -e

echo "entrypoint: starting"
echo "  R2_ACCOUNT_ID=${R2_ACCOUNT_ID:-<unset>}"
echo "  R2_BUCKET_NAME=${R2_BUCKET_NAME:-<unset>}"
echo "  CERTBOT_DOMAIN=${CERTBOT_DOMAIN:-<unset>}"
echo "  BUNNY_APIKEY=${BUNNY_APIKEY:+<set>}"

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

# 2. Download TLS certs from R2 via rclone (no FUSE required).
# Requires: R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME
# Optional: R2_CERT_FILE (default: fullchain.pem), R2_KEY_FILE (default: privkey.pem)
if [ -n "$R2_ACCOUNT_ID" ] && [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_BUCKET_NAME" ]; then
    echo "entrypoint: entering R2 block"
    CERT_DIR="/certs"
    mkdir -p "$CERT_DIR"

    # rclone handles both direct downloads (reads) and uploads (writes)
    mkdir -p /root/.config/rclone
    cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
no_check_bucket = true
EOF

    CERT="${CERT_DIR}/${R2_CERT_FILE:-fullchain.pem}"
    KEY="${CERT_DIR}/${R2_KEY_FILE:-privkey.pem}"

    echo "Downloading certs from R2: ${R2_BUCKET_NAME}"
    rclone copyto "r2:${R2_BUCKET_NAME}/${R2_CERT_FILE:-fullchain.pem}" "$CERT" 2>/dev/null || true
    rclone copyto "r2:${R2_BUCKET_NAME}/${R2_KEY_FILE:-privkey.pem}" "$KEY" 2>/dev/null || true

    echo "--- certs (${CERT_DIR}) ---"
    ls -la "${CERT_DIR}/" 2>/dev/null || echo "  (not accessible)"

    # 3. Renew cert via certbot if it expires within 30 days (or doesn't exist yet).
    # Requires: CERTBOT_DOMAIN, CERTBOT_EMAIL
    # Requires port 80 to be open for the ACME standalone HTTP challenge.
    if [ -n "$CERTBOT_DOMAIN" ] && [ -n "$CERTBOT_EMAIL" ]; then
        RENEW_THRESHOLD=$((30 * 24 * 3600))
        if [ ! -f "$CERT" ] || ! openssl x509 -checkend "$RENEW_THRESHOLD" -noout -in "$CERT" 2>/dev/null; then
            echo "Cert missing or expires within 30 days — running certbot..."
            CERTBOT_DIR="/run/letsencrypt"

            BUNNY_CREDENTIALS="/run/bunny-credentials.ini"
            echo "dns_bunny_api_key = ${BUNNY_APIKEY}" > "$BUNNY_CREDENTIALS"
            chmod 600 "$BUNNY_CREDENTIALS"

            certbot certonly \
                --authenticator dns-bunny \
                --dns-bunny-credentials "$BUNNY_CREDENTIALS" \
                --config-dir "$CERTBOT_DIR" \
                ${CERTBOT_STAGING:+--staging} \
                -d "$CERTBOT_DOMAIN" \
                --email "$CERTBOT_EMAIL" \
                --non-interactive --agree-tos

            # Copy renewed certs back to R2 so all nodes pick them up
            rclone copyto -L "${CERTBOT_DIR}/live/${CERTBOT_DOMAIN}/fullchain.pem" "r2:${R2_BUCKET_NAME}/${R2_CERT_FILE:-fullchain.pem}"
            rclone copyto -L "${CERTBOT_DIR}/live/${CERTBOT_DOMAIN}/privkey.pem"   "r2:${R2_BUCKET_NAME}/${R2_KEY_FILE:-privkey.pem}"
            echo "Renewed certs written to R2."
        else
            echo "Cert is valid for more than 30 days, skipping renewal."
        fi
    fi

    echo "--- /run/letsencrypt ---"
    find /run/letsencrypt -type f 2>/dev/null || echo "  (empty or not mounted)"

    if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
        echo "ERROR: cert files not found after all attempts:"
        echo "  cert: $CERT"
        echo "  key:  $KEY"
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
echo "entrypoint: exec moq-relay with MOQ_SERVER_TLS_CERT=${MOQ_SERVER_TLS_CERT:-<unset>}"
exec /usr/local/bin/moq-relay "$@"
