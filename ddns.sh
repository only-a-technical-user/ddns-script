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
  # Retrieve IP address from DNS record
  if [ "${PROXIED}" == "false" ]; then
    DNS_RECORD_IP=$(nslookup "${domain}" 1.1.1.1 | awk '/Address/ { print $2 }' | sed -n '2p')

    if [ -z "${DNS_RECORD_IP}" ]; then
      e "Domain '${DNS_RECORD_IP}' unable to be resolved via DNS server '1.1.1.1'"
      exit 1
    fi
    IS_PROXIED="${PROXIED}"
  fi

  # Get Proxy status and DNS record IP address from Cloudflare API, if record *should* be proxied
  if [ "${PROXIED}" == "true" ]; then
    DNS_RECORD_INFO=$(curl -s -X GET "${CLOUDFLARE_API_URL}${domain}" \
      -H "Authorization: Bearer ${ZONE_API_TOKEN}" \
      -H "Content-Type: application/json")
    if [[ ${DNS_RECORD_INFO} == *"\"success\":false"* ]]; then
      i "${DNS_RECORD_INFO}"
      e "Unable to retrieve record information from Cloudflare API"
      exit 1
    fi
    IS_PROXIED=$(echo "${DNS_RECORD_INFO}" | grep -o '"proxied":[^,]*' | grep -o '[^:]*$')
    DNS_RECORD_IP=$(echo "${DNS_RECORD_INFO}" | grep -o '"content":"[^"]*' | cut -d'"' -f 4)
  fi

  # Check if IP address or Proxy status have changed
  if [ ${dns_record_ip} == ${ip} ] && [ "${IS_PROXIED}" == "${PROXIED}" ]; then
    echo "==> DNS record IP of ${record} is ${dns_record_ip}", no changes needed.
    continue
  fi

  echo "==> DNS record of ${record} is: ${dns_record_ip}. Trying to update..."

  ### Get the dns record information from Cloudflare API
  cloudflare_record_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records?type=A&name=$record" \
    -H "Authorization: Bearer $cloudflare_zone_api_token" \
    -H "Content-Type: application/json")
  if [[ ${cloudflare_record_info} == *"\"success\":false"* ]]; then
    echo ${cloudflare_record_info}
    echo "Error! Can't get ${record} record information from Cloudflare API"
    exit 0
  fi

  ### Get the dns record id from response
  cloudflare_dns_record_id=$(echo ${cloudflare_record_info} | grep -o '"id":"[^"]*' | cut -d'"' -f4)

  ### Push new dns record information to Cloudflare API
  update_dns_record=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$cloudflare_dns_record_id" \
    -H "Authorization: Bearer $cloudflare_zone_api_token" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$record\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":$proxied}")
  if [[ ${update_dns_record} == *"\"success\":false"* ]]; then
    echo ${update_dns_record}
    echo "Error! Update failed"
    exit 0
  fi

  echo "Success!"
  echo "==> $record DNS Record updated to: $ip, ttl: $ttl, proxied: $proxied"
done
