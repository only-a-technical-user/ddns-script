#!/usr/bin/env bash

TAB="\t"

CYAN="\033[0;36m"
CYAN_BOLD="\033[0;36;1m"
RED="\033[0;31m"
RED_BOLD="\033[0;31;1m"
YELLOW="\033[0;33m"
YELLOW_BOLD="\033[0;33;1m"
GREEN="\033[0;32m"
GREEN_BOLD="\033[0;32;1m"

function now {
    echo "$(date "+%Y-%m-%d %H:%M:%S")"
}

function i {
    echo "${CYAN}$(now)${TAB}${CYAN_BOLD}INFO${TAB}${CYAN}${1}" >> "$LOG_FILE"
}

function e {
    echo "${RED}$(now)${TAB}${RED_BOLD}ERROR${TAB}${RED}$1" >> "$LOG_FILE"
}

function w {
    echo "${YELLOW}$(now)${TAB}${YELLOW_BOLD}WARNING${TAB}${YELLOW}$1" >> "$LOG_FILE"
}

function s {
    echo "${GREEN}$(now)${TAB}${GREEN_BOLD}SUCCESS${TAB}${GREEN}$1" >> "$LOG_FILE"
}

# The location of the log file to which the output is written
LOG_FILE="/home/${USER}/.ddns/logs/ddns.log"
mkdir -p "$(dirname "$LOG_FILE")"

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
CONFIG_FILE="${SCRIPT_DIR}/.env"
if [[ -n "$1" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/$1"
    i "Configuration file path: '${CONFIG_FILE}'"
fi

i "Loading configuration file"

# Validate if config file exists
if [[ -f "$CONFIG_FILE" ]]; then
    if ! source "$CONFIG_FILE"; then
        e "Configuration file '$CONFIG_FILE' has invalid syntax."
        exit 1
    fi
else
    e "Missing configuration file '$CONFIG_FILE'"
    exit 1
fi

# Ensure that the directory of the log file exists
mkdir -p "$(dirname "$LOG_FILE")"

# Check validity of "TTL" parameter
if [ "${TTL}" -lt 120 ] || [ "${TTL}" -gt 7200 ] && [ "${TTL}" -ne 1 ]; then
    e "TTL out of range (120-7200) or not set to '1'"
    exit 1
fi

# Check validity of "PROXIED" parameter
if [ "${PROXIED}" != "false" ] && [ "${PROXIED}" != "true" ]; then
    e "Incorrect 'proxied' parameter, choose 'true' or 'false'"
    exit 1
fi

# Check validity of "IP_TYPE" parameter
if [ "${IP_TYPE}" != "external" ] && [ "${IP_TYPE}" != "internal" ]; then
    e "Incorrect 'IP_TYPE' parameter, choose 'external' or 'internal'"
    exit 1
fi

# Check if set to internal IP and proxy
if [ "${IP_TYPE}" == "internal" ] && [ "${PROXIED}" == "true" ]; then
    e "Internal IP cannot be proxied"
    exit 1
fi

# Get external IP address
if [ "${IP_TYPE}" == "external" ]; then
    IP=$(curl -s -m 30 -X GET "${IP_API}")
    if [ -z "$IP" ]; then
        e "Cannot get external IP address from '${IP_API}'"
        exit 1
    fi
    if ! [[ "${IP}" =~ ${IP_REGEX} ]]; then
        e "IP Address returned was invalid"
        exit 1
    fi
    i "External IP address: '${IP}'"
fi

# Get Internal ip from primary interface
if [ "${IP_TYPE}" == "internal" ]; then
    # TODO: IMPLEMENT
    e "couldn't be bothered implementing this, will fix later"
    exit 1
fi

# Build array from DNS_RECORD variable, to update multiple domains
IFS=',' read -r -a domains <<< "$DNS_RECORD"

for domain in "${domains[@]}"; do
    i "Checking for changes for domain '${domain}'"
    DNS_RECORD_INFO=$(curl -s -X GET "${CLOUDFLARE_API_URL}${CLOUDFLARE_API_GET_PARAMS}${domain}" \
        -H "Authorization: Bearer ${ZONE_API_TOKEN}" \
        -H "Content-Type: application/json")
    if [[ ${DNS_RECORD_INFO} == *"\"success\":false"* ]]; then
        i "${DNS_RECORD_INFO}"
        e "Unable to retrieve record information from Cloudflare API"
        exit 1
    fi
    IS_PROXIED=$(echo "${DNS_RECORD_INFO}" | grep -o '"proxied":[^,]*' | grep -o '[^:]*$')
    DNS_RECORD_IP=$(echo "${DNS_RECORD_INFO}" | grep -o '"content":"[^"]*' | cut -d'"' -f 4)

    # Check if IP address or Proxy status have changed
    if [ "${DNS_RECORD_IP}" == "${IP}" ] && [ "${IS_PROXIED}" == "${PROXIED}" ]; then
        s "Domain '${domain}' requires no updates"
        continue
    fi

    i "DNS record for domain '${domain}' is outdated, updating now..."

    # Get DNS record ID
    DNS_RECORD_ID=$(echo "${DNS_RECORD_INFO}" | grep -o '"id":"[^"]*' | cut -d'"' -f4)

    ### Push new dns record information to Cloudflare API
    UPDATE_DNS_RECORD=$(curl -s -X PUT "${CLOUDFLARE_API_URL}/${DNS_RECORD_ID}" \
        -H "Authorization: Bearer ${ZONE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$IP\",\"ttl\":$TTL,\"proxied\":$PROXIED}")
    if [[ ${UPDATE_DNS_RECORD} == *"\"success\":false"* ]]; then
        i "${UPDATE_DNS_RECORD}"
        e "Update of DNS record for domain '${domain}' failed."
        exit 1
    fi

    s "DNS record for domain '${domain}' updated to: $IP, ttl: $TTL, proxied: $PROXIED"
done
