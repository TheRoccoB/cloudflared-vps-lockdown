#!/bin/bash

if ! command -v doctl &> /dev/null; then
  echo "❌ 'doctl' is not installed or not in PATH."
  exit 1
fi

echo "📡 Fetching your firewalls..."
FIREWALLS_JSON=$(doctl compute firewall list -o json)
FIREWALL_NAMES=($(echo "$FIREWALLS_JSON" | jq -r '.[].name'))
FIREWALL_IDS=($(echo "$FIREWALLS_JSON" | jq -r '.[].id'))

if [[ ${#FIREWALL_NAMES[@]} -eq 0 ]]; then
  echo "✅ No firewalls found. Nothing to delete."
  exit 0
fi

echo ""
echo "🧱 Firewalls:"
for i in "${!FIREWALL_NAMES[@]}"; do
  echo "  [$i] ${FIREWALL_NAMES[$i]} (ID: ${FIREWALL_IDS[$i]})"
done

echo ""
read -p "❌ Enter the number of the firewall to delete: " FW_INDEX
FIREWALL_ID="${FIREWALL_IDS[$FW_INDEX]}"
FIREWALL_NAME="${FIREWALL_NAMES[$FW_INDEX]}"

if [[ -z "$FIREWALL_ID" ]]; then
  echo "❌ Invalid index. Aborting."
  exit 1
fi

doctl compute firewall delete "$FIREWALL_ID" --force && \
  echo "✅ Firewall '$FIREWALL_NAME' deleted."
