#!/bin/bash

# Shared code-signing configuration for Clip's local build scripts.
#
# Use the unambiguous 40-character certificate SHA-1 shown by:
#   security find-identity -v -p codesigning
#
# A developer may persist a machine-local identity in
# `.clip-signing.local.env`; the file is ignored by Git. An explicitly set
# environment variable always wins, including `CLIP_CODE_SIGN_IDENTITY=-` for
# a deliberate ad-hoc build. With neither source present, CI keeps the
# permission-free ad-hoc default (`codesign --sign -`).
CLIP_SIGNING_CONFIG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIP_LOCAL_SIGNING_CONFIG="$CLIP_SIGNING_CONFIG_ROOT/.clip-signing.local.env"
if [[ -z "${CLIP_CODE_SIGN_IDENTITY+x}" && -f "$CLIP_LOCAL_SIGNING_CONFIG" ]]; then
  source "$CLIP_LOCAL_SIGNING_CONFIG"
fi
CLIP_CODE_SIGN_IDENTITY="${CLIP_CODE_SIGN_IDENTITY:--}"
export CLIP_CODE_SIGN_IDENTITY

clip_signing_is_ad_hoc() {
  [[ "$CLIP_CODE_SIGN_IDENTITY" == "-" ]]
}

clip_signing_identity_is_sha1() {
  [[ "${#CLIP_CODE_SIGN_IDENTITY}" -eq 40 ]] &&
    [[ "$CLIP_CODE_SIGN_IDENTITY" != *[!0-9A-Fa-f]* ]]
}

clip_normalized_signing_identity_sha1() {
  printf '%s' "$CLIP_CODE_SIGN_IDENTITY" | tr '[:lower:]' '[:upper:]'
}

clip_resolved_signing_identity_field() {
  local requested
  local match_mode
  local output_field="$1"

  requested="$CLIP_CODE_SIGN_IDENTITY"
  match_mode="name"
  if clip_signing_identity_is_sha1; then
    requested="$(clip_normalized_signing_identity_sha1)"
    match_mode="hash"
  fi

  /usr/bin/security find-identity -v -p codesigning 2>/dev/null | awk \
    -v requested="$requested" \
    -v match_mode="$match_mode" \
    -v output_field="$output_field" '
      /^[[:space:]]*[0-9]+\)/ {
        hash = toupper($2)
        name = $0
        sub(/^[^"]*"/, "", name)
        sub(/"[[:space:]]*$/, "", name)

        if ((match_mode == "hash" && hash == requested) ||
            (match_mode == "name" && name == requested)) {
          matches += 1
          if (output_field == "hash") {
            result = hash
          } else {
            result = name
          }
        }
      }
      END {
        if (matches != 1) {
          exit 1
        }
        print result
      }
    '
}

clip_resolved_signing_identity_hash() {
  clip_resolved_signing_identity_field hash
}

clip_resolved_signing_common_name() {
  clip_resolved_signing_identity_field name
}

# Xcode 26 can reject a certificate SHA-1 passed as CODE_SIGN_IDENTITY even
# though `codesign --sign` accepts the same unambiguous value. Keep the SHA-1
# as Clip's source of truth and give xcodebuild the resolved certificate name.
clip_xcode_signing_identity() {
  if clip_signing_is_ad_hoc || ! clip_signing_identity_is_sha1; then
    printf '%s\n' "$CLIP_CODE_SIGN_IDENTITY"
    return
  fi
  clip_resolved_signing_common_name
}

clip_resolved_development_team() {
  local certificate_directory
  local certificate
  local common_name
  local fingerprint
  local requested_hash
  local selected_certificate=""
  local selected_count=0
  local subject
  local team

  requested_hash="$(clip_resolved_signing_identity_hash)" || return 1
  common_name="$(clip_resolved_signing_common_name)" || return 1
  certificate_directory="$(mktemp -d "${TMPDIR:-/tmp}/clip-identity.XXXXXX")"

  if ! /usr/bin/security find-certificate \
      -a \
      -p \
      -c "$common_name" > "$certificate_directory/all.pem"; then
    rm -rf "$certificate_directory"
    return 1
  fi

  awk -v directory="$certificate_directory" '
    /-----BEGIN CERTIFICATE-----/ {
      count += 1
      output = directory "/certificate-" count ".pem"
    }
    output != "" { print > output }
    /-----END CERTIFICATE-----/ {
      close(output)
      output = ""
    }
  ' "$certificate_directory/all.pem"

  for certificate in "$certificate_directory"/certificate-*.pem; do
    [[ -f "$certificate" ]] || continue
    fingerprint="$(
      /usr/bin/openssl x509 \
        -in "$certificate" \
        -noout \
        -fingerprint \
        -sha1
    )" || continue
    fingerprint="${fingerprint#*=}"
    fingerprint="$(
      printf '%s' "$fingerprint" | tr -d ':' | tr '[:lower:]' '[:upper:]'
    )"
    if [[ "$fingerprint" == "$requested_hash" ]]; then
      selected_certificate="$certificate"
      selected_count=$((selected_count + 1))
    fi
  done

  if [[ "$selected_count" -ne 1 ]]; then
    rm -rf "$certificate_directory"
    return 1
  fi

  subject="$(
    /usr/bin/openssl x509 \
      -in "$selected_certificate" \
      -noout \
      -subject \
      -nameopt RFC2253
  )" || {
    rm -rf "$certificate_directory"
    return 1
  }
  team="$(
    printf '%s\n' "$subject" | awk -F, '
      {
        for (field_index = 1; field_index <= NF; field_index += 1) {
          field = $field_index
          sub(/^[[:space:]]*/, "", field)
          if (field ~ /^OU=/) {
            sub(/^OU=/, "", field)
            print field
            exit
          }
        }
      }
    '
  )"
  rm -rf "$certificate_directory"

  [[ "${#team}" -eq 10 ]] || return 1
  [[ "$team" != *[!0-9A-Za-z]* ]] || return 1
  printf '%s\n' "$team"
}

clip_warn_if_ad_hoc_signing() {
  if ! clip_signing_is_ad_hoc ||
     [[ "${CLIP_SUPPRESS_AD_HOC_SIGNING_WARNING:-0}" == "1" ]]; then
    return
  fi

  cat >&2 <<'EOF'
WARNING: CLIP_CODE_SIGN_IDENTITY is unset, so Clip will be ad-hoc signed.
macOS ties privacy grants to this exact build; Screen Recording and other
privacy approvals may need to be granted again after every rebuild. Set
CLIP_CODE_SIGN_IDENTITY to one stable code-signing certificate's 40-character
SHA-1 identity before permission-backed testing.
EOF
}

# Resolve the one Hardened Runtime exception needed by certificate-free builds
# that embed dynamic frameworks. Delete first so stable signing fails closed
# even if the checked-in entitlement source ever drifts.
clip_resolve_library_validation_entitlement() {
  local entitlements="$1"

  /usr/libexec/PlistBuddy \
    -c 'Delete :com.apple.security.cs.disable-library-validation' \
    "$entitlements" >/dev/null 2>&1 || true
  if clip_signing_is_ad_hoc; then
    /usr/libexec/PlistBuddy \
      -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
      "$entitlements"
  fi
}

clip_designated_requirement() {
  local app="$1"

  codesign -d -r- "$app" 2>&1 | awk '
    {
      line = $0
      sub(/^# /, "", line)
      if (!found && line ~ /^designated => /) {
        print line
        found = 1
      }
    }
  '
}

clip_embedded_leaf_certificate_sha1() {
  local app="$1"
  local certificate_directory
  local certificate_prefix
  local fingerprint

  certificate_directory="$(mktemp -d "${TMPDIR:-/tmp}/clip-signature.XXXXXX")"
  certificate_prefix="$certificate_directory/certificate"

  if ! codesign -d --extract-certificates="$certificate_prefix" "$app" \
      >/dev/null 2>&1; then
    rm -rf "$certificate_directory"
    return 1
  fi

  if ! fingerprint="$(
    /usr/bin/openssl x509 \
      -inform DER \
      -in "${certificate_prefix}0" \
      -noout \
      -fingerprint \
      -sha1
  )"; then
    rm -rf "$certificate_directory"
    return 1
  fi

  rm -rf "$certificate_directory"
  fingerprint="${fingerprint#*=}"
  printf '%s' "$fingerprint" | tr -d ':' | tr '[:lower:]' '[:upper:]'
}
