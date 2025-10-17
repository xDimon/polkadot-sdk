#!/bin/bash
[ -z "${BASH_VERSION:-}" ] && exec /usr/bin/env bash "$0" "$@"

set -euo pipefail

POLKADOT_BIN="/home/di/Projects/polkadot-sdk/target/testnet/polkadot"
COLLATOR_BIN="/home/di/Projects/polkadot-sdk/target/testnet/polkadot-parachain"
SUBKEY_BIN="/home/di/.cargo/bin/subkey"
LOGCFG="info"


# cargo build -p staging-chain-spec-builder --bin chain-spec-builder




RELAYCHAIN="rococo-local"
PARACHAIN="asset-hub-rococo-local"
PARA_BASE=2000

# Debug toggle and helper
: "${DEBUG:=0}"
dbg() {
  if [ "$DEBUG" = "1" ]; then
    printf 'DEBUG: %s\n' "$*" >&2
  fi
}

if (( $# != 4 )); then
  echo "Usage: $0 <VALIDATORS 2..8> <PARACHAINS 0..8> <COLLATORS 0..8> <WORKDIR>"
  exit 1
fi

VALIDATORS="${1:-2}"
PARACHAINS="${2:-1}"
COLLATORS="${3:-1}"
WORKDIR="${4:-tmp}"

# Basic validation
rev='^[2-8]$'
re='^[0-8]$'
[[ "$VALIDATORS"  =~ $rev ]] || { echo "VALIDATORS must be 2..8"; exit 1; }
[[ "$PARACHAINS"  =~ $re ]] || { echo "PARACHAINS must be 0..8"; exit 1; }
[[ "$COLLATORS"   =~ $re ]] || { echo "COLLATORS must be 0..8";  exit 1; }

if [ "${RMTMP:-0}" -eq "1" -a -e "$WORKDIR"  ]; then
  echo "Previous WORKDIR '$WORKDIR' was removed." >&2
  rm -Rf "$WORKDIR"
fi

if [[ -e "$WORKDIR" ]]; then
  echo "WORKDIR '$WORKDIR' already exists, remove it first." >&2
  exit 1
fi

mkdir -p -- "$WORKDIR"

dbg "WORKDIR $WORKDIR created"

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# clean
# Deletes only intermediate artifacts under $WORKDIR, keeping manifests/keys, *-raw.json, and shadow.yaml.
clean() {
  dbg "clean"

  if [ -z "${WORKDIR:-}" ]; then
    echo "ERROR: WORKDIR is not set" >&2; return 1; fi
  if [ ! -e "$WORKDIR" ]; then
    echo "Nothing to clean: $WORKDIR does not exist"; return 0; fi

  # Keep list (implicit by not touching them):
  #   - $WORKDIR/nodes/**
  #   - *-raw.json
  #   - shadow.yaml

  # Explicit intermediate patterns to remove
  local patterns=(
    "$WORKDIR/paras.json"
    "$WORKDIR/tmp.*"
    "$WORKDIR/${RELAYCHAIN}.json"
    "$WORKDIR/${RELAYCHAIN}-no-code.json"
    "$WORKDIR/${RELAYCHAIN}-val.json"
    "$WORKDIR/${RELAYCHAIN}-val-no-code.json"
    "$WORKDIR/${RELAYCHAIN}-val-paras.json"
    "$WORKDIR/${RELAYCHAIN}-val-paras-no-code.json"
    "$WORKDIR/${PARACHAIN}.json"
    "$WORKDIR/${PARACHAIN}-no-code.json"
    "$WORKDIR/${PARACHAIN}-"[0-9]*".json"
    "$WORKDIR/${PARACHAIN}-"[0-9]*"-no-code.json"
    "$WORKDIR/para-"[0-9]*"-genesis"
    "$WORKDIR/para-"[0-9]*"-wasm"
  )

  # Remove files matching patterns (without touching directories or keeps)
  local p
  for p in "${patterns[@]}"; do
    # shellcheck disable=SC2086
    for f in $p; do
      [ -e "$f" ] || continue
      # Protect raw specs and shadow.yaml just in case
      case "$f" in
        *-raw.json|*/shadow.yaml) continue ;;
      esac
      if [ -d "$f" ]; then
        continue
      fi
      dbg "rm -f -- $f"
      rm -f -- "$f" || { echo "ERROR: failed to remove $f" >&2; return 1; }
    done
  done

  dbg "Cleaned intermediates under $WORKDIR (kept nodes/, *-raw.json, shadow.yaml)"
}

# prepare_manifest <Index> <Name>
# Prepares its manifest under $WORKDIR/nodes/<lower>/
# Does NOT create p2p secret; only writes the intended node-key file path.
# Manifest includes: controller & stash (sr25519) and full session_keys (babe, gran, imon, audi, para, asgn, beef),
# each with {suri, public_hex, secret_hex, ss58}. No top-level grandpa/beefy sections. (each session key also carries its ss58)
# Also includes: node_key_file, listen_address (without peer id suffix), rpc_port, prometheus_port.
prepare_manifest() {
  local index="${1:-}"
  local name="${2:-}"
  if ! printf '%s' "${index:-}" | grep -Eq '^[0-9]+$'; then
    echo "prepare_manifest requires a non-negative integer index" >&2
    return 1
  fi
  if [ -z "$name" ]; then
    echo "prepare_manifest requires a non-empty node name" >&2
    return 1
  fi
  dbg "prepare_manifest: index=$index name=$name"
  if [ -z "${SUBKEY_BIN:-}" ] || [ ! -x "$SUBKEY_BIN" ]; then
    echo "ERROR: SUBKEY_BIN is not set or not executable: '$SUBKEY_BIN'" >&2
    return 1
  fi

  local lower
  lower="$(lc "$name")"
  local node_dir="$WORKDIR/nodes/$lower"
  mkdir -p "$node_dir" || { echo "ERROR: cannot create directory $node_dir" >&2; return 1; }

  # Port bases and computed ports
  local P2P_BASE=10000 RPC_BASE=20000 PROM_BASE=30000
  local p2p_port=$((P2P_BASE + index))
  local rpc_port=$((RPC_BASE + index))
  local prom_port=$((PROM_BASE + index))
  dbg "ports: p2p=$p2p_port rpc=$rpc_port prom=$prom_port"

  # Node key as hex (ed25519 secret) and listen address (no peer id)
  # We use the ed25519 secret hex as the libp2p node key material for dev.
  local ip_octet=$((index+1))
  local ip_prefix
  if [ -n "${USE_LOCALHOST:-}" ]; then
    ip_prefix="127.0.0"
  else
    ip_prefix="10.0.0"
  fi
  local listen_addr="/ip4/${ip_prefix}.${ip_octet}/tcp/${p2p_port}"

  # Helper to get keys
  get_key() {
    local scheme="$1"
    local suri="$2"
    local out
    if ! out="$("$SUBKEY_BIN" inspect --scheme "$scheme" "$suri" 2>&1)"; then
      echo "ERROR: subkey inspect failed for scheme=$scheme suri=$suri" >&2
      return 1
    fi

    local ss58
    if [ "$scheme" = "ecdsa" ]; then
      # Extract Public key (SS58)
      ss58="$(printf '%s\n' "$out" | awk -F': ' 'BEGIN{IGNORECASE=1} /Public key \(SS58\)/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
      if [ -z "$ss58" ]; then
        echo "ERROR: ecdsa Public key (SS58) not found for $suri" >&2
        return 1
      fi
    else
      # sr25519 / ed25519 => SS58 Address
      ss58="$(printf '%s\n' "$out" | awk -F': ' 'BEGIN{IGNORECASE=1} /SS58[[:space:]]+Address/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
      if [ -z "$ss58" ]; then
        echo "ERROR: SS58 Address not found for $scheme $suri" >&2
        return 1
      fi
    fi
    dbg "get_key: scheme=$scheme suri=$suri -> ss58=${ss58}"
    printf '%s' "$ss58"
  }

  # Helper: get public_hex and secret_hex for a key
  get_hex_pair() {
    # Prints: "<public_hex> <secret_hex>"
    local scheme="$1" suri="$2"
    local out pub sec
    if ! out="$("$SUBKEY_BIN" inspect --scheme "$scheme" "$suri" 2>&1)"; then
      echo "ERROR: subkey inspect failed for scheme=$scheme suri=$suri" >&2
      return 1
    fi
    pub="$(printf '%s\n' "$out" | awk -F': ' 'BEGIN{IGNORECASE=1}/Public key \(hex\)/{gsub(/^[ \\t]+|[ \\t]+$/, "", $2); print $2; exit}')"
    sec="$(printf '%s\n' "$out" | awk -F': ' 'BEGIN{IGNORECASE=1}/Secret key \(hex\)/{gsub(/^[ \\t]+|[ \\t]+$/, "", $2); print $2; exit}')"
    if [ -z "$sec" ]; then
      sec="$(printf '%s\n' "$out" | awk -F': ' 'BEGIN{IGNORECASE=1}/Secret seed/{gsub(/^[ \\t]+|[ \\t]+$/, "", $2); print $2; exit}')"
    fi
    if [ -z "$pub" ] || [ -z "$sec" ]; then
      echo "ERROR: cannot parse public/secret hex for $scheme $suri" >&2
      return 1
    fi
    printf '%s %s' "$pub" "$sec"
  }

  local controller_ss58 grandpa_ss58 beefy_ss58 stash_ss58
  controller_ss58="$(get_key sr25519 "//$name")" || return 1
  grandpa_ss58="$(get_key ed25519 "//$name")"    || return 1
  beefy_ss58="$(get_key ecdsa   "//$name")"     || return 1
  stash_ss58="$(get_key sr25519 "//$name//stash")" || return 1
  dbg "ss58: controller=$controller_ss58 grandpa=$grandpa_ss58 beefy=$beefy_ss58 stash=$stash_ss58"

  # Hex pairs for session roles
  local sr_pub sr_sec ed_pub ed_sec ec_pub ec_sec
  local tmp_pair
  tmp_pair="$(get_hex_pair sr25519 "//$name")" || return 1
  sr_pub="${tmp_pair%% *}"; sr_sec="${tmp_pair#* }"
  tmp_pair="$(get_hex_pair ed25519 "//$name")" || return 1
  ed_pub="${tmp_pair%% *}"; ed_sec="${tmp_pair#* }"
  tmp_pair="$(get_hex_pair ecdsa "//$name")" || return 1
  ec_pub="${tmp_pair%% *}"; ec_sec="${tmp_pair#* }"
  # For stash, also capture pub/secret
  local stash_pub stash_sec
  tmp_pair="$(get_hex_pair sr25519 "//$name//stash")" || return 1
  stash_pub="${tmp_pair%% *}"; stash_sec="${tmp_pair#* }"
  dbg "hex: sr_pub=$sr_pub ed_pub=$ed_pub ec_pub=$ec_pub stash_pub=$stash_pub"

  # Derive PeerId from the ed25519 secret (hex) via stdin to polkadot (no fallbacks)
  local peer_id=""
  if command -v "$POLKADOT_BIN" >/dev/null 2>&1; then
    dbg "peerid: via polkadot key inspect-node-key (stdin)"
    peer_id="$("$POLKADOT_BIN" key inspect-node-key <<<"${ed_sec}")" || peer_id=""
    peer_id="$(printf '%s' "$peer_id" | tr -d '\r\n' | head -c 200)"
    dbg "peerid: result='${peer_id:-}'"
  fi

  # Build session keys array with suri, public_hex, secret_hex, ss58
  local session_json
  session_json="$(jq -cn \
    --arg suri_sr "//$name" --arg suri_ed "//$name" --arg suri_ec "//$name" \
    --arg pub_sr "$sr_pub"  --arg sec_sr "$sr_sec" --arg ss58_sr "$controller_ss58" \
    --arg pub_ed "$ed_pub"  --arg sec_ed "$ed_sec" --arg ss58_ed "$grandpa_ss58" \
    --arg pub_ec "$ec_pub"  --arg sec_ec "$ec_sec" --arg ss58_ec "$beefy_ss58" '
    [
      {type:"babe", scheme:"sr25519", suri:$suri_sr, public_hex:$pub_sr, secret_hex:$sec_sr, ss58:$ss58_sr},
      {type:"aura", scheme:"sr25519", suri:$suri_sr, public_hex:$pub_sr, secret_hex:$sec_sr, ss58:$ss58_sr},
      {type:"gran", scheme:"ed25519", suri:$suri_ed, public_hex:$pub_ed, secret_hex:$sec_ed, ss58:$ss58_ed},
      {type:"imon", scheme:"sr25519", suri:$suri_sr, public_hex:$pub_sr, secret_hex:$sec_sr, ss58:$ss58_sr},
      {type:"audi", scheme:"sr25519", suri:$suri_sr, public_hex:$pub_sr, secret_hex:$sec_sr, ss58:$ss58_sr},
      {type:"para", scheme:"sr25519", suri:$suri_sr, public_hex:$pub_sr, secret_hex:$sec_sr, ss58:$ss58_sr},
      {type:"asgn", scheme:"sr25519", suri:$suri_sr, public_hex:$pub_sr, secret_hex:$sec_sr, ss58:$ss58_sr},
      {type:"beef", scheme:"ecdsa",   suri:$suri_ec, public_hex:$pub_ec, secret_hex:$sec_ec, ss58:$ss58_ec}
    ]')"

  dbg "writing manifest to $node_dir/manifest.json"
  jq -n --arg name "$name" \
    --arg controller_suri "//$name" \
    --arg controller_ss58 "$controller_ss58" \
    --arg controller_pub "$sr_pub" \
    --arg controller_sec "$sr_sec" \
    --arg stash_suri "//$name//stash" \
    --arg stash_ss58 "$stash_ss58" \
    --arg stash_pub "$stash_pub" \
    --arg stash_sec "$stash_sec" \
    --arg node_key "$ed_sec" \
    --arg listen_address "$listen_addr" \
    --arg peer_id "$peer_id" \
    --argjson rpc_port "$rpc_port" \
    --argjson prometheus_port "$prom_port" \
    --argjson session_keys "$session_json" \
    '{
      name: $name,
      controller: { scheme: "sr25519", suri: $controller_suri, ss58: $controller_ss58, public_hex: $controller_pub, secret_hex: $controller_sec },
      stash:      { scheme: "sr25519", suri: $stash_suri,      ss58: $stash_ss58,      public_hex: $stash_pub,      secret_hex: $stash_sec },
      session_keys: $session_keys,
      node_key: $node_key,
      listen_address: $listen_address,
      peer_id: $peer_id,
      rpc_port: $rpc_port,
      prometheus_port: $prometheus_port
    }' > "$node_dir/manifest.json" || { echo "ERROR: failed to write manifest.json" >&2; return 1; }

  if [ -f "$node_dir/manifest.json" ]; then
    dbg "manifest ok; session_keys ss58: $(jq -rc '[.session_keys[]|{t:.type,s:.scheme,x:.ss58}]' "$node_dir/manifest.json" 2>/dev/null | cut -c1-200)"
  else
    echo "ERROR: manifest not found after write: $node_dir/manifest.json" >&2
    return 1
  fi

  echo "Prepared manifest for $name (index $index): $node_dir/manifest.json"
}


# clean_dev_validators_patch <SPEC_JSON>
# Clears validator session keys, balances, and bootNodes in the patch section.
clean_dev_validators_patch() {
  local spec_path="$1"
  if [ -z "$spec_path" ] || [ ! -f "$spec_path" ]; then
    echo "clean_dev_validators_patch: Spec file not found: $spec_path" >&2
    return 1
  fi
  local tmp_out
  tmp_out="$(mktemp "$WORKDIR/tmp.clean.XXXXXX")"
  jq '
    .genesis = (.genesis // {}) |
    .genesis.runtimeGenesis = (.genesis.runtimeGenesis // {}) |
    .genesis.runtimeGenesis.patch = (.genesis.runtimeGenesis.patch // {}) |
    .genesis.runtimeGenesis.patch.session = (.genesis.runtimeGenesis.patch.session // {}) |
    .genesis.runtimeGenesis.patch.session.keys = [] |
    .genesis.runtimeGenesis.patch.balances = (.genesis.runtimeGenesis.patch.balances // {}) |
    .genesis.runtimeGenesis.patch.balances.balances = [] |
    .bootNodes = []
  ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"
  echo "Validator session keys, balances, and bootNodes cleared in $spec_path"
}

# clean_dev_collators_patch <SPEC_JSON> <PARA_ID>
# Clears balances and session keys and sets parachain ids to PARA_ID
clean_dev_collators_patch() {
  local spec_path="$1" para_id="$2"
  if [ -z "$spec_path" ] || [ ! -f "$spec_path" ]; then
    echo "clean_dev_collators_patch: Spec file not found: $spec_path" >&2; return 1; fi
  if ! printf '%s' "$para_id" | grep -Eq '^[0-9]+$'; then
    echo "clean_dev_collators_patch: PARA_ID must be an integer" >&2; return 1; fi
  local tmp_out
  tmp_out="$(mktemp "$WORKDIR/tmp.cleanpara.XXXXXX")"
  jq --argjson pid "$para_id" '
    .para_id = $pid |
    .genesis = (.genesis // {}) |
    .genesis.runtimeGenesis = (.genesis.runtimeGenesis // {}) |
    .genesis.runtimeGenesis.patch = (.genesis.runtimeGenesis.patch // {}) |
    .genesis.runtimeGenesis.patch.parachainInfo = (
      .genesis.runtimeGenesis.patch.parachainInfo // {}
    ) |
    .genesis.runtimeGenesis.patch.parachainInfo.parachainId = $pid |
    .genesis.runtimeGenesis.patch.collatorSelection = (
      .genesis.runtimeGenesis.patch.collatorSelection // {}
    ) |
    .genesis.runtimeGenesis.patch.collatorSelection.invulnerables = [] |
    .genesis.runtimeGenesis.patch.balances = (
      .genesis.runtimeGenesis.patch.balances // {}
    ) |
    .genesis.runtimeGenesis.patch.balances.balances = [] |
    .genesis.runtimeGenesis.patch.session = (
      .genesis.runtimeGenesis.patch.session // {}
    ) |
    .genesis.runtimeGenesis.patch.session.keys = []
  ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"
  echo "Parachain patch cleaned and para_id set to $para_id in $spec_path"
}

#
# add_dev_validators_patch <SPEC_JSON> <VALIDATOR_NAME>
# Adds or updates a validator's session keys, balances, and bootNodes in the patch section.
add_dev_validators_patch() {
    local spec_path="$1"
    local validator_name="$2"
    if [ -z "$spec_path" ] || [ ! -f "$spec_path" ]; then
        echo "add_dev_validators_patch: Spec file not found: $spec_path" >&2
        return 1
    fi
    if [ -z "$validator_name" ]; then
        echo "add_dev_validators_patch: Validator name required" >&2
        return 1
    fi
    local lower
    lower="$(lc "$validator_name")"
    local manifest="$WORKDIR/nodes/$lower/manifest.json"
    if [ ! -f "$manifest" ]; then
        echo "add_dev_validators_patch: Manifest not found for validator $validator_name at $manifest" >&2
        return 1
    fi
    # Read controller, grandpa, beefy addresses
    local controller_ss58 grandpa_ss58 beefy_ss58 stash_ss58
    controller_ss58="$(jq -r '.controller.ss58' "$manifest")"
    stash_ss58="$(jq -r '.stash.ss58' "$manifest")"
    grandpa_ss58="$(jq -r '.session_keys[]|select(.type=="gran")|.ss58' "$manifest")"
    beefy_ss58="$(jq -r '.session_keys[]|select(.type=="beef")|.ss58' "$manifest")"
    if [ -z "$controller_ss58" ] || [ -z "$grandpa_ss58" ] || [ -z "$beefy_ss58" ] || [ -z "$stash_ss58" ]; then
        echo "add_dev_validators_patch: Missing key data in manifest for $validator_name" >&2
        return 1
    fi
    # Check if this is the first validator being added (before modifying session keys)
    local is_first
    is_first="$(jq -r '((.genesis.runtimeGenesis.patch.session.keys // []) | length) == 0' "$spec_path")"
    # Build session key entry
    local session_entry
    session_entry="$(jq -cn \
        --arg controller "$controller_ss58" \
        --arg grandpa "$grandpa_ss58" \
        --arg beefy "$beefy_ss58" \
        '[ $controller, $controller, {
            authority_discovery: $controller,
            babe: $controller,
            beefy: $beefy,
            grandpa: $grandpa,
            para_assignment: $controller,
            para_validator: $controller
        } ]')"
    # Remove any existing entry with same controller, append new one
    local tmp_out
    tmp_out="$(mktemp "$WORKDIR/tmp.addval.XXXXXX")"
    jq --argjson new_entry "$session_entry" --arg controller "$controller_ss58" '
        .genesis = (.genesis // {}) |
        .genesis.runtimeGenesis = (.genesis.runtimeGenesis // {}) |
        .genesis.runtimeGenesis.patch = (.genesis.runtimeGenesis.patch // {}) |
        .genesis.runtimeGenesis.patch.session = (.genesis.runtimeGenesis.patch.session // {}) |
        .genesis.runtimeGenesis.patch.session.keys = (
          (.genesis.runtimeGenesis.patch.session.keys // [])
          | map(select(.[0] != $controller))
          + [$new_entry]
        )
    ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"
    # If this is the first added validator, set Sudo key to its controller address
    if [ "$is_first" = "true" ]; then
      tmp_out="$(mktemp "$WORKDIR/tmp.addval.XXXXXX")"
      jq --arg controller "$controller_ss58" '
        .genesis = (.genesis // {}) |
        .genesis.runtimeGenesis = (.genesis.runtimeGenesis // {}) |
        .genesis.runtimeGenesis.patch = (.genesis.runtimeGenesis.patch // {}) |
        .genesis.runtimeGenesis.patch.sudo = (
          (.genesis.runtimeGenesis.patch.sudo // {})
        ) |
        .genesis.runtimeGenesis.patch.sudo.key = $controller
      ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"
      echo "Sudo key set to controller of $validator_name"
    fi
    # Add/update balances for controller and stash
    local amount_controller_default="1000000000000000000"
    local amount_stash_default="1000000000000000000"
    tmp_out="$(mktemp "$WORKDIR/tmp.addval.XXXXXX")"
    jq --arg controller "$controller_ss58" --arg stash "$stash_ss58" \
       --argjson amt_controller "$amount_controller_default" \
       --argjson amt_stash "$amount_stash_default" '
      .genesis = (.genesis // {}) |
      .genesis.runtimeGenesis = (.genesis.runtimeGenesis // {}) |
      .genesis.runtimeGenesis.patch = (.genesis.runtimeGenesis.patch // {}) |
      .genesis.runtimeGenesis.patch.balances = (.genesis.runtimeGenesis.patch.balances // {}) |
      .genesis.runtimeGenesis.patch.balances.balances = (
        (.genesis.runtimeGenesis.patch.balances.balances // [])
        | map(select(.[0] != $controller and .[0] != $stash))
        + [[$controller, $amt_controller], [$stash, $amt_stash]]
      )
    ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"
    # Append bootNode
    local listen_address peer_id bootnode
    listen_address="$(jq -r '.listen_address' "$manifest")"
    peer_id="$(jq -r '.peer_id' "$manifest")"
    if [ -n "$listen_address" ] && [ -n "$peer_id" ]; then
        bootnode="${listen_address}/p2p/${peer_id}"
        tmp_out="$(mktemp "$WORKDIR/tmp.addval.XXXXXX")"
        jq --arg bootnode "$bootnode" '
          .bootNodes = ((.bootNodes // []) + [$bootnode] | unique)
        ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"
    fi
    echo "Validator $validator_name added or updated in $spec_path"
}

# add_dev_collators_patch <SPEC_JSON> <COLLATOR_NAME>
# Adds Aura session key entry for a collator from its manifest
add_dev_collators_patch() {
  local spec_path="$1" collator_name="$2"
  if [ -z "$spec_path" ] || [ ! -f "$spec_path" ]; then
    echo "add_dev_collators_patch: Spec file not found: $spec_path" >&2; return 1; fi
  if [ -z "$collator_name" ]; then
    echo "add_dev_collators_patch: Collator name required" >&2; return 1; fi
  local lower manifest controller_ss58 aura_ss58 tmp_out
  lower="$(lc "$collator_name")"
  manifest="$WORKDIR/nodes/$lower/manifest.json"
  if [ ! -f "$manifest" ]; then
    echo "add_dev_collators_patch: Manifest not found for $collator_name at $manifest" >&2; return 1; fi
  controller_ss58="$(jq -r '.controller.ss58' "$manifest")"
  aura_ss58="$(jq -r '.session_keys[]|select(.type=="aura")|.ss58' "$manifest")"
  if [ -z "$controller_ss58" ] || [ -z "$aura_ss58" ]; then
    echo "add_dev_collators_patch: Missing controller/aura ss58 in manifest for $collator_name" >&2; return 1; fi
  # Build session key entry with only Aura for parachain
  local entry
  entry="$(jq -cn --arg acc "$controller_ss58" --arg aura "$aura_ss58" '[ $acc, $acc, { aura: $aura } ]')"
  tmp_out="$(mktemp "$WORKDIR/tmp.addcol.XXXXXX")"
  jq --argjson new_entry "$entry" --arg acc "$controller_ss58" '
    .genesis = (.genesis // {}) |
    .genesis.runtimeGenesis = (.genesis.runtimeGenesis // {}) |
    .genesis.runtimeGenesis.patch = (.genesis.runtimeGenesis.patch // {}) |
    .genesis.runtimeGenesis.patch.session = (.genesis.runtimeGenesis.patch.session // {}) |
    .genesis.runtimeGenesis.patch.session.keys = (
      (.genesis.runtimeGenesis.patch.session.keys // [])
      | map(select(.[0] != $acc))
      + [$new_entry]
    )
  ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"

  # Ensure collator is invulnerable
  tmp_out="$(mktemp "$WORKDIR/tmp.addcol.XXXXXX")"
  jq --arg acc "$controller_ss58" '
    .genesis = (.genesis // {}) |
    .genesis.runtimeGenesis = (.genesis.runtimeGenesis // {}) |
    .genesis.runtimeGenesis.patch = (.genesis.runtimeGenesis.patch // {}) |
    .genesis.runtimeGenesis.patch.collatorSelection = (
      .genesis.runtimeGenesis.patch.collatorSelection // {}
    ) |
    .genesis.runtimeGenesis.patch.collatorSelection.invulnerables = (
      ((.genesis.runtimeGenesis.patch.collatorSelection.invulnerables // []) + [$acc])
      | unique
    )
  ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"

  # Append bootNode for collator
  local listen_address peer_id bootnode
  listen_address="$(jq -r '.listen_address // empty' "$manifest")"
  peer_id="$(jq -r '.peer_id // empty' "$manifest")"
  if [ -n "$listen_address" ] && [ -n "$peer_id" ]; then
    bootnode="${listen_address}/p2p/${peer_id}"
    tmp_out="$(mktemp "$WORKDIR/tmp.addcol.XXXXXX")"
    jq --arg bootnode "$bootnode" '
      .bootNodes = ((.bootNodes // []) + [$bootnode] | unique)
    ' "$spec_path" > "$tmp_out" && mv "$tmp_out" "$spec_path"
  fi

  echo "Collator $collator_name (Aura) added to $spec_path"
}


# replace_runtime_code <INPUT_SPEC.json> <OUTPUT_SPEC.json> [HEX_CODE]
# Writes HEX_CODE (default: 0xdeadcode) into .genesis.runtimeGenesis.code
replace_runtime_code() {
  local input_spec_path="$1"
  local output_spec_path="$2"
  local new_code="0xdeadcode"

  # --- sanity checks (English comments for clarity) ---
  if [ -z "$input_spec_path" ] || [ ! -f "$input_spec_path" ]; then
    echo "replace_runtime_code: Input spec not found: $input_spec_path" >&2
    return 1
  fi
  if [ -z "$output_spec_path" ]; then
    echo "replace_runtime_code: Output spec path is required" >&2
    return 1
  fi

  # Ensure hex code starts with 0x (not strictly required, but safer)
  case "$new_code" in
  0x*) : ;;
  *) new_code="0x${new_code}" ;;
  esac

  # --- write .genesis.runtimeGenesis.code (create path if missing) ---
  jq --arg code "$new_code" '
    .genesis as $g
    | .genesis = ($g // {})
    | .genesis.runtimeGenesis = (.genesis.runtimeGenesis // {})
    | .genesis.runtimeGenesis.code = $code
  ' "$input_spec_path" > "$output_spec_path"

  dbg "replace_runtime_code: output: $output_spec_path"
}


# provision_node_keys <Name> <SPEC_JSON>
provision_node_keys() {
  local validator_name="$1"
  local spec_json="$2"

  # --- validate tools & args ---
  if [ -z "${POLKADOT_BIN:-}" ] || [ ! -x "$POLKADOT_BIN" ]; then
    echo "ERROR: POLKADOT_BIN is not set/executable" >&2; return 1; fi
  if [ -z "${SUBKEY_BIN:-}" ] || [ ! -x "$SUBKEY_BIN" ]; then
    echo "ERROR: SUBKEY_BIN is not set/executable" >&2; return 1; fi
  if [ -z "$validator_name" ] || [ -z "$spec_json" ] || [ ! -f "$spec_json" ]; then
    echo "Usage: provision_node_keys <Name> <SPEC_JSON>" >&2; return 1; fi

  local lower node_dir base_path
  lower="$(echo "$validator_name" | tr '[:upper:]' '[:lower:]')"
  node_dir="$WORKDIR/nodes/$lower"
  base_path="$node_dir/base"
  mkdir -p "$base_path" || { echo "ERROR: cannot mkdir -p $base_path" >&2; return 1; }

  # Validate manifest exists
  if [ ! -f "$node_dir/manifest.json" ]; then
    echo "ERROR: manifest not found for validator $validator_name at $node_dir/manifest.json" >&2
    return 1
  fi

  # --- chain id ---
  local chain_id
  chain_id="$(jq -r '.id // empty' "$spec_json")"
  if [ -z "$chain_id" ]; then echo "ERROR: .id not found in $spec_json" >&2; return 1; fi

  dbg "provision_node_keys: $base_path (chain: $chain_id) for $validator_name (from manifest) =="

  # --- session keys from manifest ---
  local ktype_map ktype kscheme suri
  local insert_fail=0
  # Mapping: babe->babe, imon->imon, audi->audi, para->para, asgn->asgn, gran->gran, beef->beef
  jq -c '.session_keys[]' "$node_dir/manifest.json" | while read -r key; do
    ktype="$(echo "$key" | jq -r '.type')"
    kscheme="$(echo "$key" | jq -r '.scheme')"
    suri="$(echo "$key" | jq -r '.suri')"
    # Defensive: skip if missing
    [ -z "$ktype" ] && continue
    if "$POLKADOT_BIN" key insert \
      --base-path "$base_path" \
      --chain "$spec_json" \
      --key-type "$ktype" \
      --scheme "$kscheme" \
      --suri "$suri" >/dev/null 2>&1; then
      dbg "  + inserted $ktype ($kscheme) from manifest"
    else
      echo "ERROR: failed to insert $ktype ($kscheme) from manifest for $validator_name" >&2
      insert_fail=1
      break
    fi
  done
  if [ "$insert_fail" -ne 0 ]; then
    return 1
  fi
  dbg "Session keystore populated from manifest: $base_path (chain: $chain_id) for $validator_name"

  # --- p2p key from manifest ---
  local p2p_dir="$base_path/chains/$chain_id/network"
  local p2p_file="$p2p_dir/secret_ed25519"
  mkdir -p "$p2p_dir" || { echo "ERROR: cannot mkdir -p $p2p_dir" >&2; return 1; }
  local node_key_hex
  node_key_hex="$(jq -r '.node_key // empty' "$node_dir/manifest.json")"
  if [ -z "$node_key_hex" ]; then echo "ERROR: node_key not found in manifest" >&2; return 1; fi
  printf '%s' "$node_key_hex" | xxd -r -p > "$p2p_file" || { echo "ERROR: failed to write p2p secret from manifest" >&2; return 1; }
  chmod 600 "$p2p_file"
  dbg "P2P secret written from manifest: $p2p_file"

  # --- read PeerId for log (prefer polkadot key inspect-node-key --file) ---
  local peer_id=""
  if "$POLKADOT_BIN" key inspect-node-key --help 2>&1 | grep -q -- '--file'; then
    peer_id="$("$POLKADOT_BIN" key inspect-node-key --file "$p2p_file" 2>/dev/null \
      | awk -F': ' 'BEGIN{IGNORECASE=1}/Peer[[:space:]]*ID/{print $2; exit}')"
  fi
  if [ -z "$peer_id" ]; then
    # Last resort: match 12D3Koo…-like
    peer_id="$(strings "$p2p_file" 2>/dev/null | grep -Eo '12D3Koo[1-9A-HJ-NP-Za-km-z]+' | head -n1)"
  fi
  [ -n "$peer_id" ] && echo "PeerId (from manifest p2p key): $peer_id"

  echo "$validator_name provisioned by keys from manifest"
}

# patch_relay_with_paras <RELAY_SPEC_IN.json> <PARAS_FILE.json> <RELAY_SPEC_OUT.json>
# Appends parachain entries from $PARAS_FILE into relay spec's patch.paras.paras
patch_relay_with_paras() {
  local relay_in="$1" paras_json="$2" relay_out="$3"
  if [ -z "$relay_in" ] || [ ! -f "$relay_in" ]; then
    echo "patch_relay_with_paras: relay spec not found: $relay_in" >&2; return 1; fi
  if [ -z "$paras_json" ] || [ ! -f "$paras_json" ]; then
    echo "patch_relay_with_paras: paras file not found: $paras_json" >&2; return 1; fi
  if [ -z "$relay_out" ]; then
    echo "patch_relay_with_paras: output path required" >&2; return 1; fi

  local tmp_out
  tmp_out="$(mktemp "$WORKDIR/tmp.relayparas.XXXXXX")"; _tmp_files+=("$tmp_out")
  jq --slurpfile paras "$paras_json" '
    .genesis                         //= {} |
    .genesis.runtimeGenesis          //= {} |
    .genesis.runtimeGenesis.patch    //= {} |
    .genesis.runtimeGenesis.patch.paras        //= {} |
    .genesis.runtimeGenesis.patch.paras.paras  = (
      (.genesis.runtimeGenesis.patch.paras.paras // []) + $paras[0]
    )
  ' "$relay_in" > "$tmp_out" && mv -- "$tmp_out" "$relay_out"
  echo "Relay spec patched with parachain data → $relay_out"
}

# print_run_command <Name>
# Prints a one-line command to start a node using data from the manifest
print_validator_run_command() {
  dbg print_validator_run_command $@

  local validator_name="$1"
  if [ -z "$validator_name" ]; then
    echo "Usage: print_run_command <Name>" >&2; return 1; fi

  local lower node_dir base_path manifest
  lower="$(echo "$validator_name" | tr '[:upper:]' '[:lower:]')"
  node_dir="$WORKDIR/nodes/$lower"
  manifest="$node_dir/manifest.json"
  base_path="$node_dir/base"

  if [ ! -f "$manifest" ]; then
    echo "ERROR: manifest not found for $validator_name at $manifest" >&2
    return 1
  fi

  # prefer raw-spec if it exists, otherwise validator spec; else error
  local spec_json
  if [ -f "$WORKDIR/$RELAYCHAIN-raw.json" ]; then
    spec_json="$WORKDIR/$RELAYCHAIN-raw.json"
  else
    echo "ERROR: spec json not found (expected $WORKDIR/$RELAYCHAIN-raw.json)" >&2
    return 1
  fi

  # derive chain id (used to reference p2p secret location)
  local chain_id
  chain_id="$(jq -r '.id // empty' "$spec_json")"
  if [ -z "$chain_id" ]; then
    echo "ERROR: .id not found in $spec_json" >&2; return 1; fi

  # read ports and listen address from manifest
  local listen_addr rpc_port prom_port node_key_hex
  listen_addr="$(jq -r '.listen_address // empty' "$manifest")"
  rpc_port="$(jq -r '.rpc_port // empty' "$manifest")"
  prom_port="$(jq -r '.prometheus_port // empty' "$manifest")"
  node_key_hex="$(jq -r '.node_key // empty' "$manifest")"
  if [ -z "$listen_addr" ] || [ -z "$rpc_port" ] || [ -z "$prom_port" ] || [ -z "$node_key_hex" ]; then
    echo "ERROR: manifest missing listen_address/node_key/rpc_port/prometheus_port" >&2
    return 1
  fi

  # p2p secret file (optional: not required to pass on cmd if base-path is correct)
  local p2p_file="$base_path/chains/$chain_id/network/secret_ed25519"
  local p2p_note=""
  [ -f "$p2p_file" ] || p2p_note=" # (warning: p2p secret not found yet; run provision_node_keys)"

  # compose command (single line)
  local cmd
  cmd="SHADOW_TAG=\"$validator_name\" \"$POLKADOT_BIN\" \\
    --validator \\
    --name \"$validator_name\" \\
    --base-path \"$base_path\" \\
    --chain \"$spec_json\" \\
    --listen-addr \"$listen_addr\" \\
    --node-key \"$node_key_hex\" \\
    --rpc-port $rpc_port \\
    --rpc-cors all \\
    --rpc-methods unsafe \\
    --prometheus-port $prom_port \\
    --prometheus-external \\
    --no-mdns \\
    --no-telemetry \\
    --no-hardware-benchmarks \\
    --insecure-validator-i-know-what-i-do \\
    -l$LOGCFG > \"$validator_name.log\" 2>&1 &"
  # print it nicely for copy-paste
  echo "$cmd$p2p_note"
}

# print_collator_run_command <Name> <PARACHAIN_SPEC_JSON>
# Prints a one-line command to start a collator. Relay ports/RPC are ignored; node key may be temporary.
print_collator_run_command() {
  dbg print_collator_run_command $@

  local collator_name="$1"
  local para_spec_json="$2"
  if [ -z "$collator_name" ] || [ -z "$para_spec_json" ]; then
    echo "Usage: print_collator_run_command <Name> <PARACHAIN_SPEC_JSON>" >&2; return 1; fi
  if [ ! -f "$para_spec_json" ]; then
    echo "ERROR: parachain spec not found: $para_spec_json" >&2; return 1; fi

  local lower node_dir base_path manifest
  lower="$(echo "$collator_name" | tr '[:upper:]' '[:lower:]')"
  node_dir="$WORKDIR/nodes/$lower"
  manifest="$node_dir/manifest.json"
  base_path="$node_dir/base"

  # Relay spec (not critical here): prefer RAW, else VAL
  local relay_spec_json
  if [ -f "$WORKDIR/$RELAYCHAIN-raw.json" ]; then
    relay_spec_json="$WORKDIR/$RELAYCHAIN-raw.json"
  else
    relay_spec_json=""  # allowed to be empty per request
  fi

  # read ports and listen address from manifest
  local listen_addr rpc_port prom_port node_key_hex
  listen_addr="$(jq -r '.listen_address // empty' "$manifest")"
  rpc_port="$(jq -r '.rpc_port // empty' "$manifest")"
  prom_port="$(jq -r '.prometheus_port // empty' "$manifest")"
  node_key_hex="$(jq -r '.node_key // empty' "$manifest")"
  if [ -z "$listen_addr" ] || [ -z "$rpc_port" ] || [ -z "$prom_port" ] || [ -z "$node_key_hex" ]; then
    echo "ERROR: manifest missing listen_address/node_key/rpc_port/prometheus_port" >&2
    return 1
  fi

  # compose command (single line). Relay args are optional and appended after `--` if available.
  local cmd
  cmd="SHADOW_TAG=\"$collator_name\" \"$COLLATOR_BIN\" \\
    --collator \\
    --force-authoring \\
    --name \"$collator_name\" \\
    --base-path \"$base_path\" \\
    --chain \"$para_spec_json\" \\
    --listen-addr \"$listen_addr\" \\
    --node-key \"$node_key_hex\" \\
    --rpc-port $rpc_port \\
    --rpc-cors all \\
    --rpc-methods unsafe \\
    --prometheus-port $prom_port \\
    --prometheus-external \\
    --no-mdns \\
    --no-telemetry \\
    --no-hardware-benchmarks \\
    -l$LOGCFG \\
    -- \\
    --base-path \"$base_path/../relay\" \\
    --chain \"$relay_spec_json\" \\
    --no-prometheus \\
    --no-mdns \\
    --no-telemetry \\
    --no-hardware-benchmarks \\
    -l$LOGCFG > \"$collator_name.log\" 2>&1 &"
  echo "$cmd"
}

print_run_commands() {
  dbg print_run_commands

  for ((v=0;v<VALIDATORS;v++)); do
    echo
    print_validator_run_command "Validator_$((v+1))" "$WORKDIR/$RELAYCHAIN-raw.json" || exit 1
  done
  for ((p=0;p<PARACHAINS;p++)); do
    for ((c=0;c<COLLATORS;c++)); do
      echo
      print_collator_run_command "Collator_$((PARA_BASE+p))_$((c+1))" "$WORKDIR/$PARACHAIN-$((PARA_BASE+p))-raw.json" || exit 1
    done
  done
}

# generate_shadow_config
# Produce Shadow YAML where each validator/collator runs on its own host.
# Output: $WORKDIR/shadow.yaml
generate_shadow_config() {
  dbg generate_shadow_config

  local out="$WORKDIR/shadow.yaml"
  mkdir -p -- "$WORKDIR" || { echo "ERROR: cannot mkdir -p $WORKDIR" >&2; return 1; }

  # Build ordered list of host labels from actual node names
  local host_labels=()
  local name lower node_dir manifest
  for ((v=0; v<VALIDATORS; v++)); do
    name="Validator_$((v+1))"
    lower="$(lc "$name")"; node_dir="$WORKDIR/nodes/$lower"; manifest="$node_dir/manifest.json"
    [ -f "$manifest" ] || { echo "WARN: manifest missing for $name: $manifest — skipping" >&2; continue; }
    host_labels+=("$name")
  done
  for ((p=0; p<PARACHAINS; p++)); do
    for ((c=0; c<COLLATORS; c++)); do
      name="Collator_$((PARA_BASE+p))_$((c+1))"
      lower="$(lc "$name")"; node_dir="$WORKDIR/nodes/$lower"; manifest="$node_dir/manifest.json"
      [ -f "$manifest" ] || { echo "WARN: manifest missing for $name: $manifest — skipping" >&2; continue; }
      host_labels+=("$name")
    done
  done
  local total_hosts="${#host_labels[@]}"

  # Header + detailed full-mesh graph in GML (nodes 1..N correspond to host_labels order)
  {
    printf 'general:\n'
    printf '  stop_time: "20 min"\n'
    printf '  model_unblocked_syscall_latency: true\n'

    printf '\n'
    printf 'experimental:\n'
    printf '  native_preemption_enabled: true\n'
    printf '  unblocked_syscall_latency: "1 microseconds"\n'
#    printf '  strace_logging_mode: deterministic\n'
    printf '  report_errors_to_stderr: true\n'
#    printf '  use_new_tcp: true\n'
    printf '  socket_send_autotune: true\n'
    printf '  socket_recv_autotune: true\n'
    printf '  socket_send_buffer: "4 MiB"\n'
    printf '  socket_recv_buffer: "4 MiB"\n'

    printf '\n'
    printf 'network:\n'
    printf '  graph:\n'
    printf '    type: gml\n'
    printf '    inline: |\n'
    printf '      graph [\n'
    printf '        directed 0\n'
    # nodes with labels
    local i j
    for ((i=1; i<=total_hosts; i++)); do
      printf '        node [\n'
      printf '          id %d\n' "$i"
      printf '          label "%s"\n' "${host_labels[$((i-1))]}"
      printf '          host_bandwidth_up "1 Gbit"\n'
      printf '          host_bandwidth_down "1 Gbit"\n'
      printf '        ]\n'
    done
    # full mesh with self-edges; undirected (directed 0)
    for ((i=1; i<=total_hosts; i++)); do
      # self-edge to define loopback characteristics
      printf '        edge [\n'
      printf '          source %d\n' "$i"
      printf '          target %d\n' "$i"
      printf '          latency "1 ms"\n'
      printf '          packet_loss 0.0\n'
      printf '        ]\n'
    done
    for ((i=1; i<=total_hosts; i++)); do
      for ((j=i+1; j<=total_hosts; j++)); do
        printf '        edge [\n'
        printf '          source %d\n' "$i"
        printf '          target %d\n' "$j"
        printf '          latency "1 ms"\n'
        printf '          packet_loss 0.0\n'
        printf '        ]\n'
      done
    done
    printf '      ]\n'
    printf '\n'
    printf 'hosts:\n'
  } >"$out"

  local ip_prefix
  if [ -n "${USE_LOCALHOST:-}" ]; then
    ip_prefix="127.0.0"
  else
    ip_prefix="10.0.0"
  fi
  local ip_octet=1
  local lower node_dir base_path manifest listen_addr rpc_port prom_port node_key_hex spec_json relay_spec_json name host

  # Prefer RAW relay spec if exists, else VAL spec (path used by collators after --)
  if [ -f "$WORKDIR/$RELAYCHAIN-raw.json" ]; then
    relay_spec_json="$WORKDIR/$RELAYCHAIN-raw.json"
  fi

  # Start network node id counter
  local net_id=1

  #############################
  # Validators → one host each
  #############################
  for ((v=0; v<VALIDATORS; v++)); do
    name="Validator_$((v+1))"
    lower="$(lc "$name")"
    node_dir="$WORKDIR/nodes/$lower"
    base_path="$node_dir/base"
    manifest="$node_dir/manifest.json"

    if [ ! -f "$manifest" ]; then
      echo "WARN: manifest missing for $name: $manifest — skipping" >&2; continue
    fi

    listen_addr="$(jq -r '.listen_address // empty' "$manifest")"
    rpc_port="$(jq -r '.rpc_port // empty' "$manifest")"
    prom_port="$(jq -r '.prometheus_port // empty' "$manifest")"
    node_key_hex="$(jq -r '.node_key // empty' "$manifest")"

    # Validators always use the relay RAW (already generated below in the script)
    spec_json="$WORKDIR/$RELAYCHAIN-raw.json"

    host="$name"
    local host_key
    host_key="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    printf '  %s:\n' "$host_key" >>"$out"
    printf '    network_node_id: %d\n' "$net_id" >>"$out"
    printf '    ip_addr: %s.%d\n' "$ip_prefix" "$ip_octet" >>"$out"
    printf '    processes:\n' >>"$out"
    printf '      - path: %s\n' "$POLKADOT_BIN" >>"$out"
    printf '        args: [\n' >>"$out"
    printf '          "--validator",\n' >>"$out"
    printf '          "--name", "%s",\n' "$name" >>"$out"
    printf '          "--base-path", "%s",\n' "$base_path" >>"$out"
    printf '          "--chain", "%s",\n' "$spec_json" >>"$out"
    printf '          "--listen-addr", "%s",\n' "$listen_addr" >>"$out"
    printf '          "--node-key", "%s",\n' "$node_key_hex" >>"$out"
    printf '          "--rpc-port", "%s",\n' "$rpc_port" >>"$out"
    printf '          "--prometheus-port", "%s",\n' "$prom_port" >>"$out"
    printf '          "--prometheus-external",\n' >>"$out"
    printf '          "--no-mdns",\n' >>"$out"
    printf '          "--no-telemetry",\n' >>"$out"
    printf '          "--no-hardware-benchmarks",\n' >>"$out"
    printf '          "--no-beefy",\n' >>"$out"
    printf '          "--insecure-validator-i-know-what-i-do",\n' >>"$out"
    printf '          "-l%s"\n' "$LOGCFG" >>"$out"
    printf '        ]\n' >>"$out"
    printf '        environment:\n' >>"$out"
    printf '          RUST_BACKTRACE: "1"\n' >>"$out"
    printf '          COLORBT_SHOW_HIDDEN: "1"\n' >>"$out"
    printf '          RUST_STDOUT_FLUSH_ON_WRITE: "1"\n' >>"$out"
    printf '          RUST_LOG: "%s"\n' "$LOGCFG" >>"$out"
    printf '          SHADOW_TAG: "%s"\n' "$host" >>"$out"
    printf '        expected_final_state: running\n' >>"$out"

    ip_octet=$((ip_octet+1))
    net_id=$((net_id+1))
  done

  #############################
  # Collators → one host each
  #############################
  for ((p=0; p<PARACHAINS; p++)); do
    id=$((PARA_BASE+p))
    # Parachain RAW spec path (assembled earlier in the script)
    local para_raw="$WORKDIR/$PARACHAIN-$id-raw.json"

    for ((c=0; c<COLLATORS; c++)); do
      name="Collator_$((PARA_BASE+p))_$((c+1))"
      lower="$(lc "$name")"
      node_dir="$WORKDIR/nodes/$lower"
      base_path="$node_dir/base"
      manifest="$node_dir/manifest.json"

      if [ ! -f "$manifest" ]; then
        echo "WARN: manifest missing for $name: $manifest — skipping" >&2; continue
      fi

      listen_addr="$(jq -r '.listen_address // empty' "$manifest")"
      rpc_port="$(jq -r '.rpc_port // empty' "$manifest")"
      prom_port="$(jq -r '.prometheus_port // empty' "$manifest")"
      node_key_hex="$(jq -r '.node_key // empty' "$manifest")"

      host="$name"
      local host_key
      host_key="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
      printf '  %s:\n' "$host_key" >>"$out"
      printf '    network_node_id: %d\n' "$net_id" >>"$out"
      printf '    ip_addr: %s.%d\n' "$ip_prefix" "$ip_octet" >>"$out"
      printf '    processes:\n' >>"$out"
      printf '      - path: %s\n' "$COLLATOR_BIN" >>"$out"
      printf '        args: [\n' >>"$out"
      printf '          "--collator",\n' >>"$out"
      printf '          "--force-authoring",\n' >>"$out"
      printf '          "--name", "%s",\n' "$name" >>"$out"
      printf '          "--base-path", "%s",\n' "$base_path" >>"$out"
      printf '          "--chain", "%s",\n' "$para_raw" >>"$out"
      printf '          "--listen-addr", "%s",\n' "$listen_addr" >>"$out"
      printf '          "--node-key", "%s",\n' "$node_key_hex" >>"$out"
      printf '          "--rpc-port", "%s",\n' "$rpc_port" >>"$out"
      printf '          "--prometheus-port", "%s",\n' "$prom_port" >>"$out"
      printf '          "--prometheus-external",\n' >>"$out"
      printf '          "--no-mdns",\n' >>"$out"
      printf '          "--no-telemetry",\n' >>"$out"
      printf '          "--no-hardware-benchmarks",\n' >>"$out"
      printf '          "-l%s",\n' "$LOGCFG" >>"$out"
      printf '          "--",\n' >>"$out"
      printf '          "--base-path", "%s/../relay",\n' "$base_path" >>"$out"
      printf '          "--chain", "%s",\n' "$relay_spec_json" >>"$out"
      printf '          "--no-prometheus",\n' >>"$out"
      printf '          "--no-mdns",\n' >>"$out"
      printf '          "--no-telemetry",\n' >>"$out"
      printf '          "--no-hardware-benchmarks",\n' >>"$out"
      printf '          "--no-beefy",\n' >>"$out"
      printf '          "-l%s"\n' "$LOGCFG" >>"$out"
      printf '        ]\n' >>"$out"
      printf '        environment:\n' >>"$out"
      printf '          RUST_BACKTRACE: "1"\n' >>"$out"
      printf '          COLORBT_SHOW_HIDDEN: "1"\n' >>"$out"
      printf '          RUST_STDOUT_FLUSH_ON_WRITE: "1"\n' >>"$out"
      printf '          RUST_LOG: "%s"\n' "$LOGCFG" >>"$out"
      printf '          SHADOW_TAG: "%s"\n' "$host" >>"$out"
      printf '        expected_final_state: running\n' >>"$out"

      ip_octet=$((ip_octet+1))
      net_id=$((net_id+1))
    done
  done

  echo "Shadow config written: $out"
}

# Generate manifests for validators
for ((v=0;v<VALIDATORS;v++)); do
  prepare_manifest "$v" "Validator_$((v+1))" || exit 1
done

# Generate manifests for collators
for ((p=0;p<PARACHAINS;p++)); do
  for ((c=0;c<COLLATORS;c++)); do
    i=$((VALIDATORS + (p * COLLATORS) + c))
    prepare_manifest "$i" "Collator_$((PARA_BASE+p))_$((c+1))" || exit 1
  done
done

# Patch spec by validators
"$POLKADOT_BIN" build-spec --chain "$RELAYCHAIN" --disable-default-bootnode  > "$WORKDIR/$RELAYCHAIN.json" 2>/dev/null
cp "$WORKDIR/$RELAYCHAIN.json" "$WORKDIR/$RELAYCHAIN-val.json"
clean_dev_validators_patch "$WORKDIR/$RELAYCHAIN-val.json"
for ((v=0;v<VALIDATORS;v++)); do
  add_dev_validators_patch "$WORKDIR/$RELAYCHAIN-val.json" "Validator_$((v+1))" || exit 1
done

# Generate parachain artifacts
"$COLLATOR_BIN" build-spec --chain "$PARACHAIN" --disable-default-bootnode > "$WORKDIR/$PARACHAIN.json" 2>/dev/null

# no-code spec for debugging
replace_runtime_code "$WORKDIR/$RELAYCHAIN.json" "$WORKDIR/$RELAYCHAIN-no-code.json"
replace_runtime_code "$WORKDIR/$RELAYCHAIN-val.json" "$WORKDIR/$RELAYCHAIN-val-no-code.json"
replace_runtime_code "$WORKDIR/$PARACHAIN.json" "$WORKDIR/$PARACHAIN-no-code.json"

paras_file="$WORKDIR/paras.json"
printf '[]' > "$paras_file"

for ((p=0; p<PARACHAINS; p++)); do
  id=$((PARA_BASE+p))
  gfile="$WORKDIR/para-${id}-genesis"
  wfile="$WORKDIR/para-${id}-wasm"

  cp "$WORKDIR/$PARACHAIN.json" "$WORKDIR/$PARACHAIN-$id.json"

  dbg clean_dev_collators_patch "$WORKDIR/$PARACHAIN-$id.json" "$id"

  clean_dev_collators_patch "$WORKDIR/$PARACHAIN-$id.json" "$id"
  for ((c=0;c<COLLATORS;c++)); do

    dbg add_dev_collators_patch "$WORKDIR/$PARACHAIN-$id.json" "Collator_$((PARA_BASE+p))_$((c+1))"

    add_dev_collators_patch "$WORKDIR/$PARACHAIN-$id.json" "Collator_$((PARA_BASE+p))_$((c+1))" || exit 1
  done

  "$COLLATOR_BIN" export-genesis-state --chain "$WORKDIR/$PARACHAIN-$id.json" "$gfile" >/dev/null 2>/dev/null
  "$COLLATOR_BIN" export-genesis-wasm  --chain "$WORKDIR/$PARACHAIN-$id.json" "$wfile" >/dev/null 2>/dev/null

  tmp_paras="$(mktemp)"; _tmp_files+=("$tmp_paras")
  jq --rawfile gh "$gfile" --rawfile vc "$wfile" --argjson id "$id" \
    '. + [[ $id, [ ($gh|gsub("[\r\n]";"")), ($vc|gsub("[\r\n]";"")), true ] ]]' \
    "$paras_file" > "$tmp_paras"
  mv -- "$tmp_paras" "$paras_file"

  "$COLLATOR_BIN" build-spec --chain "$WORKDIR/$PARACHAIN-$id.json" --disable-default-bootnode --raw > "$WORKDIR/$PARACHAIN-$id-raw.json" 2>/dev/null
  replace_runtime_code "$WORKDIR/$PARACHAIN-$id.json" "$WORKDIR/$PARACHAIN-$id-no-code.json"
done

# Patch relay (validators spec) with collected parachain entries
patch_relay_with_paras "$WORKDIR/$RELAYCHAIN-val.json" "$paras_file" "$WORKDIR/${RELAYCHAIN}-val-paras.json" || exit 1
replace_runtime_code "$WORKDIR/${RELAYCHAIN}-val-paras.json" "$WORKDIR/${RELAYCHAIN}-val-paras-no-code.json"

# Generate raw-spec
"$POLKADOT_BIN" build-spec --chain "$WORKDIR/${RELAYCHAIN}-val-paras.json" --raw > "$WORKDIR/$RELAYCHAIN-raw.json" 2>/dev/null

# Provide keys for validators
for ((v=0;v<VALIDATORS;v++)); do
  provision_node_keys "Validator_$((v+1))" "$WORKDIR/$RELAYCHAIN-raw.json" || exit 1
done

# Provide keys for collators
for ((p=0;p<PARACHAINS;p++)); do
  for ((c=0;c<COLLATORS;c++)); do
    id=$((PARA_BASE+p))
    provision_node_keys "Collator_$((PARA_BASE+p))_$((c+1))" "$WORKDIR/$PARACHAIN-$id-raw.json" || exit 1
  done
done

# Clean
clean

# Print run commands
print_run_commands

# Generate Shadow simulation YAML
generate_shadow_config || exit 1

#    echo "#################################################################################################"
#    echo "##################    Simulation: $VALIDATORS validators + $PARACHAINS parachains * $COLLATORS collators    ##################"
#    echo "#################################################################################################"
#    cat $WORKDIR/shadow.yaml
#    echo "##################################################################################################"
