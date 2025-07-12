#!/bin/bash
set -euo pipefail

VARS_FILE="vars.yaml"
secret=${secret:-$(yq e '.vultr_api_key' "$VARS_FILE")} 

# Step 1: Prompt for inputs
echo "Available OS images:"
curl -s -H "Authorization: Bearer $secret" \
     -H "Accept: application/json" https://api.vultr.com/v2/os | jq '.os[] | "\(.id): \(.name)"'
read -p "Enter desired OS ID (for this playbook, choose Alpine Linux, which at last check is 2076): " os_id

echo "Available plans:"
curl -s -H "Authorization: Bearer $secret" \
     -H "Accept: application/json" https://api.vultr.com/v2/plans | jq '.plans[] | .id'
read -p "Enter desired plan ID (vc2-1c-0.5gb is sufficient for me): " plan

echo "Locations for that plan:"
curl -s -H "Authorization: Bearer $secret" \
     -H "Accept: application/json" https://api.vultr.com/v2/plans | jq --arg plan "$plan" \
     '.plans[] | select(.id == $plan) | .locations'
read -p "Enter desired region (e.g., ewr): " region

# Step 2: Fill in vars.yaml
yq e -i ".os_id = $os_id | .plan = \"$plan\" | .region = \"$region\"" "$VARS_FILE"

label=$(yq e '.label' "$VARS_FILE")
hostname=$(yq e '.hostname' "$VARS_FILE")

# Step 3: Launch instance and capture instance ID
echo "Launching instance..."

# Run ansible just to render the cloud-config file
ansible-playbook render-cloud-config.yaml --extra-vars "@$VARS_FILE"

# Read and base64 encode cloud-config for the API
cloud_config_base64=$(base64 -w 0 rendered-cloud-config.yaml)

# Build JSON payload in shell or using jq
payload=$(jq -n --arg region "$region" \
                 --arg plan "$plan" \
                 --arg os_id "$os_id" \
                 --arg label "$label" \
                 --arg hostname "$hostname" \
                 --arg user_data "$cloud_config_base64" \
'{
  region: $region,
  plan: $plan,
  os_id: ($os_id | tonumber),
  label: $label,
  hostname: $hostname,
  user_data: $user_data
}')

# Make the API call with curl, capture response and instance ID
response=$(curl -s -H "Authorization: Bearer $secret" \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "https://api.vultr.com/v2/instances")

instance_id=$(echo "$response" | jq -r '.instance.id // empty')

if [[ -z "$instance_id" ]]; then
  echo "Error creating instance:"
  echo "$response"
  exit 1
fi

echo "Launched instance with ID: $instance_id"


# Wait until instance has an IP
while :; do
  host_ip=$(curl -s -H "Authorization: Bearer $secret" \
    -H "Accept: application/json" \
    "https://api.vultr.com/v2/instances/$instance_id" | jq -r '.instance.main_ip')

  if [[ -n "$host_ip" && "$host_ip" != "null" && "$host_ip" != "0.0.0.0" ]]; then
    break
  fi

  echo "Waiting for instance to report IP..."
  duration=20  # seconds to "sleep"
  spinchars='|/-\'
  end=$((SECONDS + duration))

  i=0
  while [ $SECONDS -lt $end ]; do
    printf "\rWaiting... %s" "${spinchars:i++%${#spinchars}:1}"
    sleep 0.1
  done
done

# Fail if no IP
if [[ -z "$host_ip" || "$host_ip" == "null" ]]; then
    echo "Failed to obtain IP for instance."
    exit 1
fi

echo "Instance IP: $host_ip"

# Step 5: Wait for SSH to come up
echo -n "Waiting for SSH"
for _ in {1..60}; do
    if nc -z "$host_ip" 22 2>/dev/null; then
        echo " — SSH is up"
        break
    fi
    echo -n "."
    sleep 5
done

# Fail if no SSH
if ! nc -z "$host_ip" 22 2>/dev/null; then
    echo "SSH did not become available"
    exit 1
fi

echo "sleeping for 30..."
sleep 30

# Step 6: SSH keyscan
echo "Scanning SSH host key..."
ssh-keygen -R "$host_ip" 2>/dev/null || true
ssh-keyscan -H "$host_ip" >> ~/.ssh/known_hosts

mkdir -p downloaded-configs

# Step 7: Run full configuration playbook
echo "Running Ansible configuration playbook..."
ansible-playbook configure-server.yaml \
  -i "$host_ip," \
  --private-key "$(yq e '.ssh_key_base' "$VARS_FILE")" \
  -u "$(yq e '.username' "$VARS_FILE")" \
  --extra-vars "server_ip=$host_ip" 

echo "Done."

# Step 8: Copy WireGuard client config to /etc/wireguard
echo "Copying WireGuard client config to /etc/wireguard..."
sudo cp downloaded-configs/wg-client.conf /etc/wireguard
