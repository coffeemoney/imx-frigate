#!/bin/bash

echo "===== Cloudflare Tunnel Setup (API + curl) ====="

read -p "Enter your Cloudflare API Token: " CF_API_TOKEN
read -p "Enter your Cloudflare Account ID: " CF_ACCOUNT_ID
read -p "Enter your domain name (example: example.com): " DOMAIN_NAME
read -p "Enter Tunnel Name: " TUNNEL_NAME
read -p "Enter DNS hostname for the tunnel (e.g. tunnel.example.com): " TUNNEL_HOSTNAME
read -p "Enter service URL to expose (e.g. http://localhost:8080): " SERVICE_URL

echo "Fetching Zone ID for $DOMAIN_NAME ..."

ZONE_LOOKUP_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN_NAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json")

CF_ZONE_ID=$(echo "$ZONE_LOOKUP_RESPONSE" | grep -oE '"id":"[a-z0-9]+"' | head -n 1 | cut -d':' -f2 | tr -d '"')

if [ -z "$CF_ZONE_ID" ]; then
  echo "Failed to get Zone ID. Response:"
  echo "$ZONE_LOOKUP_RESPONSE"
  exit 1
fi

echo "Zone ID found: $CF_ZONE_ID"

echo "Creating tunnel..."

CREATE_TUNNEL_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"name\":\"$TUNNEL_NAME\"}")

TUNNEL_ID=$(echo "$CREATE_TUNNEL_RESPONSE" | grep -oE '"id":"[a-z0-9]+"' | head -n 1 | cut -d':' -f2 | tr -d '"')

if [ -z "$TUNNEL_ID" ]; then
  echo "Failed to create tunnel. Response:"
  echo "$CREATE_TUNNEL_RESPONSE"
  exit 1
fi

echo "Tunnel created successfully!"
echo "Tunnel ID: $TUNNEL_ID"

echo "Creating DNS route..."

DNS_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{
    \"type\":\"CNAME\",
    \"name\":\"$TUNNEL_HOSTNAME\",
    \"content\":\"$TUNNEL_ID.cfargotunnel.com\",
    \"proxied\":true
  }")

if [[ "$DNS_RESPONSE" != *"success\":true"* ]]; then
  echo "DNS creation failed:"
  echo "$DNS_RESPONSE"
  exit 1
fi

echo "DNS record created!"

echo "Fetching tunnel token (run token)..."

TOKEN_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json")

TUNNEL_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '"token":"[^"]+"' | cut -d':' -f2 | tr -d '"')

if [ -z "$TUNNEL_TOKEN" ]; then
  echo "Failed to fetch tunnel token:"
  echo "$TOKEN_RESPONSE"
  exit 1
fi

echo ""
echo "===== Tunnel Token ====="
echo "$TUNNEL_TOKEN"
echo "========================"
echo ""
echo "Use this token in your next step."
