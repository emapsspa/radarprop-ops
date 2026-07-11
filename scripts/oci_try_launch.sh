#!/usr/bin/env bash
set -Eeuo pipefail

required=(
  COMPARTMENT_ID
  AVAILABILITY_DOMAIN
  IMAGE_ID
  SUBNET_ID
  SSH_KEY_FILE
  OCPUS
  MEMORY_GB
  DISPLAY_NAME
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::$name está vacío."
    exit 20
  fi
done

if [[ ! -f "$SSH_KEY_FILE" ]]; then
  echo "::error::No existe SSH_KEY_FILE: $SSH_KEY_FILE"
  exit 21
fi

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

set_output() {
  local key="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

echo "=================================================="
echo "RADARPROP CHILE - OCI A1 CAPACITY HUNTER"
echo "=================================================="
echo "Shape: VM.Standard.A1.Flex"
echo "OCPU: $OCPUS"
echo "RAM: ${MEMORY_GB} GB"
echo "AD: $AVAILABILITY_DOMAIN"
echo "Nombre: $DISPLAY_NAME"
echo "Región: ${OCI_CLI_REGION:-no definida}"
echo "=================================================="

# Evita instancias duplicadas si una ejecución anterior tuvo éxito.
EXISTING_JSON="$(
  oci compute instance list \
    --compartment-id "$COMPARTMENT_ID" \
    --display-name "$DISPLAY_NAME" \
    --all \
    --output json
)"

EXISTING_ID="$(
  jq -r '
    .data[]
    | select(
        .["lifecycle-state"] != "TERMINATED"
        and .["lifecycle-state"] != "TERMINATING"
      )
    | .id
  ' <<< "$EXISTING_JSON" | head -n 1
)"

if [[ -n "$EXISTING_ID" ]]; then
  EXISTING_STATE="$(
    oci compute instance get \
      --instance-id "$EXISTING_ID" \
      --query 'data."lifecycle-state"' \
      --raw-output
  )"

  echo "Ya existe una instancia RadarProp:"
  echo "OCID: $EXISTING_ID"
  echo "Estado: $EXISTING_STATE"

  set_output "instance_exists" "true"
  set_output "instance_id" "$EXISTING_ID"
  set_output "instance_state" "$EXISTING_STATE"

  summary "## RadarProp OCI"
  summary ""
  summary "Ya existe una instancia con nombre \`$DISPLAY_NAME\`."
  summary ""
  summary "- Estado: \`$EXISTING_STATE\`"
  summary "- OCID: \`$EXISTING_ID\`"

   if [[ "$EXISTING_STATE" == "RUNNING" ]]; then

    PUBLIC_IP="$(
      oci compute instance list-vnics \
        --instance-id "$EXISTING_ID" \
        --query 'data[0]."public-ip"' \
        --raw-output
    )"

    echo "IP pública: $PUBLIC_IP"

    set_output "public_ip" "$PUBLIC_IP"
    set_output "instance_ready" "true"
    set_output "capacity_wait" "false"

    summary "- IP pública: \`$PUBLIC_IP\`"

  else

    echo
    echo "La instancia existe pero todavía no está RUNNING."
    echo "Estado actual: $EXISTING_STATE"
    echo "Se programará una nueva comprobación automática."

    set_output "instance_ready" "false"
    set_output "capacity_wait" "true"

    summary ""
    summary "La instancia todavía está en estado \`$EXISTING_STATE\`."
    summary ""
    summary "Se realizará una nueva comprobación automática."

  fi

  exit 0
fi

ERROR_FILE="$(mktemp)"
trap 'rm -f "$ERROR_FILE"' EXIT

set +e
INSTANCE_ID="$(
  oci compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AVAILABILITY_DOMAIN" \
    --shape "VM.Standard.A1.Flex" \
    --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$SSH_KEY_FILE" \
    --display-name "$DISPLAY_NAME" \
    --query 'data.id' \
    --raw-output \
    2>"$ERROR_FILE"
)"
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 && "$INSTANCE_ID" == ocid1.instance.* ]]; then
  echo
  echo "##################################################"
  echo "#           INSTANCIA A1 CREADA                 #"
  echo "##################################################"
  echo
  echo "Instance OCID: $INSTANCE_ID"

  set_output "instance_exists" "true"
  set_output "instance_id" "$INSTANCE_ID"

  echo "Esperando estado RUNNING..."

  oci compute instance get \
    --instance-id "$INSTANCE_ID" \
    --wait-for-state RUNNING \
    --wait-interval-seconds 15 \
    --max-wait-seconds 900 >/dev/null

  PUBLIC_IP="$(
    oci compute instance list-vnics \
      --instance-id "$INSTANCE_ID" \
      --query 'data[0]."public-ip"' \
      --raw-output
  )"

  echo "Instancia RUNNING."
  echo "IP pública: $PUBLIC_IP"

  set_output "instance_state" "RUNNING"
  set_output "instance_ready" "true"
  set_output "public_ip" "$PUBLIC_IP"

  summary "## ✅ RadarProp aprovisionado"
  summary ""
  summary "- Estado: \`RUNNING\`"
  summary "- OCID: \`$INSTANCE_ID\`"
  summary "- IP pública: \`$PUBLIC_IP\`"
  summary ""
  summary "El workflow intentará desactivar su programación automática."

  exit 0
fi

ERROR_TEXT="$(cat "$ERROR_FILE")"
printf '%s\n' "$ERROR_TEXT"


# ============================================================
# 1. SIN CAPACIDAD OCI
# ============================================================

if grep -qiE \
  "Out of host capacity|Out of capacity" \
  <<< "$ERROR_TEXT"
then

  echo
  echo "[CAPACIDAD] OCI todavía no tiene capacidad A1 disponible."
  echo "La siguiente ejecución automática volverá a intentarlo."

  set_output "instance_exists" "false"
  set_output "instance_ready" "false"
  set_output "capacity_wait" "true"

  summary "## RadarProp OCI"
  summary ""
  summary "⏳ Sin capacidad A1 disponible en este intento."
  summary ""
  summary "La siguiente ejecución automática volverá a intentarlo."

  exit 0
fi


# ============================================================
# 2. THROTTLING OCI
# ============================================================

if grep -qiE \
  "TooManyRequests|429" \
  <<< "$ERROR_TEXT"
then

  echo
  echo "[THROTTLING] OCI limitó temporalmente las solicitudes."
  echo "La siguiente ejecución automática volverá a intentarlo."

  set_output "instance_exists" "false"
  set_output "instance_ready" "false"
  set_output "capacity_wait" "true"

  summary "## RadarProp OCI"
  summary ""
  summary "⏳ OCI aplicó limitación temporal."
  summary ""
  summary "La siguiente ejecución automática volverá a intentarlo."

  exit 0
fi


# ============================================================
# 3. ERROR TRANSITORIO DE RED / ENDPOINT
# ============================================================

if grep -qiE \
  "RequestException|connection to endpoint timed out|timed out|Timeout|ConnectTimeout|ReadTimeout|ConnectionError|Connection reset|RemoteDisconnected|Temporary failure in name resolution|Name or service not known|ServiceUnavailable|Bad Gateway|Gateway Timeout|HTTP 502|HTTP 503|HTTP 504" \
  <<< "$ERROR_TEXT"
then

  echo
  echo "[RED] Error temporal de conexión con OCI."
  echo
  echo "El error NO se considera una configuración inválida."
  echo "La cadena continuará automáticamente."
  echo

  set_output "instance_exists" "false"
  set_output "instance_ready" "false"
  set_output "capacity_wait" "true"

  summary "## RadarProp OCI"
  summary ""
  summary "🌐 Error temporal de conexión con OCI."
  summary ""
  summary "La ejecución no se considera fallida."
  summary ""
  summary "Se realizará un nuevo intento automáticamente."

  exit 0
fi


# ============================================================
# 4. ERROR REAL DE CONFIGURACIÓN O SERVICIO
# ============================================================

echo
echo "=================================================="
echo "ERROR NO RECUPERABLE"
echo "=================================================="
echo
echo "El error no corresponde a:"
echo
echo "- falta de capacidad"
echo "- throttling"
echo "- timeout"
echo "- error temporal de red"
echo
echo "La automatización se detiene para evitar repetir"
echo "una posible configuración incorrecta."

set_output "instance_exists" "false"
set_output "instance_ready" "false"
set_output "capacity_wait" "false"

summary "## ❌ Error de configuración o servicio"
summary ""
summary "El error no corresponde a una condición temporal conocida."
summary ""
summary "Revisa el log de la ejecución."

exit 1
