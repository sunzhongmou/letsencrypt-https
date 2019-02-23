#!/bin/bash

set -e
set -u
set -o pipefail

[[ -n "${ZSH_VERSION:-}" ]] && set -o SH_WORD_SPLIT && set +o FUNCTION_ARGZERO && set -o NULL_GLOB && set -o noglob
[[ -z "${ZSH_VERSION:-}" ]] && shopt -s nullglob && set -f

exec 3>&-
exec 4>&-

source letscommon.sh


CA="https://acme-staging-v02.api.letsencrypt.org/directory"
CA_ACCOUNT=
CA_NEW_ORDER="https://acme-staging-v02.api.letsencrypt.org/acme/new-order"
CA_NEW_NONCE="https://acme-staging-v02.api.letsencrypt.org/acme/new-nonce"
CA_NEW_ACCOUNT="https://acme-staging-v02.api.letsencrypt.org/acme/new-acct"

OPENSSL_CNF=
[[ -z "${OPENSSL_CNF}" ]] && OPENSSL_CNF="$(openssl version -d | cut -d\" -f2)/openssl.cnf"

ACCOUNT_KEY_JSON="./cert/account-key.json"
ACCOUNT_ID=
ACCOUNT_URL=
FQDN="abcd.sunzhongmou.com"
SUBJ=""
CHALLENGE_TYPE="dns-01"
CERTDIR="./cert"

pubExponent64=
pubMod64=
thumbPrint=

challenge_names=()
challenge_tokens=()
challenge_uris=()
keyauth=
keyauth_hook=
keyauths=()
deploy_args=()
num_pending_challenges=

_generate_account_key() {
    echo " + Generating account key..."
    openssl genrsa -out "${1}" 2048
}

_register_account() {
    echo "+ Registering account key with ACME server..."
    local accountKey="${1}"

    pubExponent64="$(printf '%x' "$(openssl rsa -in "${accountKey}" -noout -text | awk '/publicExponent/ {print $2}')" | hex2bin | urlbase64)"
    pubMod64="$(openssl rsa -in "${accountKey}" -noout -modulus | cut -d'=' -f2 | hex2bin | urlbase64)"

    nonce="$(http_request HEAD "${CA_NEW_NONCE}" | grep -i ^Replay-Nonce: | awk -F ': ' '{print $2}' | tr -d '\n\r')"
    header='{"alg": "RS256", "jwk": {"e": "'"${pubExponent64}"'", "kty": "RSA", "n": "'"${pubMod64}"'"}}'

    protected='{"alg": "RS256", "jwk": {"e": "'"${pubExponent64}"'", "kty": "RSA", "n": "'"${pubMod64}"'"}, "url": "'"${CA_NEW_ACCOUNT}"'", "nonce": "'"${nonce}"'"}'
    protected64="$(printf '%s' "${protected}" | urlbase64)"

    payload='{"contact":["mailto:'me@sunwei.xyz'"], "termsOfServiceAgreed": true}'
    payload64=$(printf '%s' "${payload}" | urlbase64)

    signed64="$(printf '%s' "${protected64}.${payload64}" | openssl dgst -sha256 -sign "${accountKey}" | urlbase64)"
    data='{"protected": "'"${protected64}"'", "payload": "'"${payload64}"'", "signature": "'"${signed64}"'"}'

    http_request POST "${CA_NEW_ACCOUNT}" "${data}" > "${ACCOUNT_KEY_JSON}"

    if [[ -e "${ACCOUNT_KEY_JSON}" ]]; then
        ACCOUNT_ID="$(cat "${ACCOUNT_KEY_JSON}" | get_json_int_value id)"
        CA_ACCOUNT=${CA_NEW_ACCOUNT/new-acct/acct}
        ACCOUNT_URL="${CA_ACCOUNT}/${ACCOUNT_ID}"
    fi
}

_new_order(){
    accountKey="${1}"
#    echo "> Requesting new cert order from Let's Encrypt CA..."

    payload='{"identifiers": [{"type": "dns", "value": "abcd.sunzhongmou.com"}]}'
    payload64=$(printf '%s' "${payload}" | urlbase64)

    nonce="$(http_request HEAD "${CA_NEW_NONCE}" | grep -i ^Replay-Nonce: | awk -F ': ' '{print $2}' | tr -d '\n\r')"

    header='{"alg": "RS256", "jwk": {"e": "'"${pubExponent64}"'", "kty": "RSA", "n": "'"${pubMod64}"'"}}'
    protected='{"alg": "RS256", "kid": "'"${ACCOUNT_URL}"'", "url": "'"${CA_NEW_ORDER}"'", "nonce": "'"${nonce}"'"}'
    protected64="$(printf '%s' "${protected}" | urlbase64)"

    signed64="$(printf '%s' "${protected64}.${payload64}" | openssl dgst -sha256 -sign "${accountKey}" | urlbase64)"
    data='{"protected": "'"${protected64}"'", "payload": "'"${payload64}"'", "signature": "'"${signed64}"'"}'

    http_request POST "${CA_NEW_ORDER}" "${data}"
}

_build_deploy_args() {
    local certOrder="${1}"

    order_authorizations="$(echo ${certOrder} | get_json_array_value authorizations)"

    local idx=0
    for uri in ${order_authorizations}; do
        authorizations[${idx}]="$(echo "${uri}" | sed -E -e 's/\"(.*)".*/\1/' | clean_json)"
        idx=$((idx+1))
    done
    echo " + Received ${idx} authorizations URLs from the CA"

    thumbPrint="$(printf '{"e":"%s","kty":"RSA","n":"%s"}' "${pubExponent64}" "${pubMod64}" | openssl dgst -sha256 -binary | urlbase64)"

    local idx=0
    for authorization in ${authorizations[*]}; do
        response="$(http_request GET "${authorization}" | clean_json)"
        identifier="$(echo "${response}" | get_json_dict_value identifier | get_json_string_value value)"
        echo " + Handling authorization for ${identifier}"


        if [[ "valid" = "$(echo "${response}" | sed -E 's/"challenges": \[\{.*\}\]//' | get_json_string_value status)" ]]; then
            echo " + Found valid authorization for ${identifier}"
            continue
        fi

        # Find challenge in authorization
        challenges="$(echo "${response}" | sed -E 's/.*"challenges": \[(\{.*\})\].*/\1/')"
        challenge="$(<<<"${challenges}" sed -E -e 's/^[^\[]+\[(.+)\]$/\1/' -e 's/\}(, (\{)|(\]))/}\'$'\n''\2/g' | grep \""${CHALLENGE_TYPE}"\" || true)"
        # If the specified challenge type is not found, exit with error and show the valid types
        if [ -z "${challenge}" ]; then
          allowed_validations="$(grep -Eo '"type": "[^"]+"' <<< "${challenges}" | grep -Eo ' "[^"]+"' | _sed -e 's/"//g' -e 's/^ //g')"
          _exiterr "Validating this certificate is not possible using ${CHALLENGE_TYPE}. Possible validation methods are: ${allowed_validations}"
        fi

        # Gather challenge information
        challenge_names[${idx}]="${identifier}"
        challenge_tokens[${idx}]="$(echo "${challenge}" | get_json_string_value token)"
        challenge_uris[${idx}]="$(echo "${challenge}" | get_json_string_value url)"

        # Prepare challenge tokens and deployment parameters
        keyauth="${challenge_tokens[${idx}]}.${thumbPrint}"
        keyauth_hook="$(printf '%s' "${keyauth}" | openssl dgst -sha256 -binary | urlbase64)"
        keyauths[${idx}]="${keyauth}"
        deploy_args[${idx}]="${identifier} ${challenge_tokens[${idx}]} ${keyauth_hook}"

        idx=$((idx+1))
    done

    num_pending_challenges=${idx}
    echo " + ${num_pending_challenges} pending challenge(s)"
}

_create_txt_record() {
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"
    echo "Create TXT record : ${DOMAIN}, ${TOKEN_FILENAME}, ${TOKEN_VALUE}"

    loginToken='83717,32ff6aa5112b7bdaf64f48763c4788c4'
    uri="https://dnsapi.cn/Record.Create"
    recordType="TXT"

    data='{"login_token": "'"${loginToken}"'", "record_type": "'"${recordType}"'", "value": "'"${TOKEN_VALUE}"'", "domain": "sunzhongmou.com", "sub_domain": "_acme-challenge.abcd", "format": "json", "record_line": "默认"}'
#    http_request POST ${uri} ${data}
    curl -X POST https://dnsapi.cn/Record.Create -d "login_token=83717,32ff6aa5112b7bdaf64f48763c4788c4&format=json&domain=sunzhongmou.com&sub_domain=_acme-challenge.abcd&record_type=TXT&value=${TOKEN_VALUE}&record_line=默认"

    sleep 5
}

_remove_txt_record() {
#    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}" RECORD_ID="${4}"
#    echo "Remove TXT record : ${DOMAIN}, ${TOKEN_FILENAME}, ${TOKEN_VALUE}"
#
#    loginToken='83717,32ff6aa5112b7bdaf64f48763c4788c4'
#    uri="https://dnsapi.cn/Record.Remove"
#
#    data='{"login_token": "'"${loginToken}"'", "domain": "sunzhongmou.com", "record_id": "'"${RECORD_ID}"'", "format": "json"}'
#    http_request POST ${uri} ${data}
    echo 'todo'
}

_deploy_challenge() {
    local idx=0
    while [ ${idx} -lt ${num_pending_challenges} ]; do
        _create_txt_record ${deploy_args[${idx}]}
        idx=$((idx+1))
    done
}

_clean_challenge() {
    local idx=0
    while [ ${idx} -lt ${num_pending_challenges} ]; do
        _remove_txt_record ${deploy_args[${idx}]}
        idx=$((idx+1))
    done
}

_validate_pending_challenge() {
    local accountKey="${1}"
    local idx=0
    while [ ${idx} -lt ${num_pending_challenges} ]; do
        echo " + Responding to challenge for ${challenge_names[${idx}]} authorization..."
        # Ask the acme-server to verify our challenge and wait until it is no longer pending

        payload='{"keyAuthorization": "'"${keyauths[${idx}]}"'"}'
        payload64=$(printf '%s' "${payload}" | urlbase64)

        nonce="$(http_request HEAD "${CA_NEW_NONCE}" | grep -i ^Replay-Nonce: | awk -F ': ' '{print $2}' | tr -d '\n\r')"

        header='{"alg": "RS256", "jwk": {"e": "'"${pubExponent64}"'", "kty": "RSA", "n": "'"${pubMod64}"'"}}'
        protected='{"alg": "RS256", "kid": "'"${ACCOUNT_URL}"'", "url": "'"${challenge_uris[${idx}]}"'", "nonce": "'"${nonce}"'"}'
        protected64="$(printf '%s' "${protected}" | urlbase64)"

        signed64="$(printf '%s' "${protected64}.${payload64}" | openssl dgst -sha256 -sign "${accountKey}" | urlbase64)"
        data='{"protected": "'"${protected64}"'", "payload": "'"${payload64}"'", "signature": "'"${signed64}"'"}'

        result="$(http_request POST "${challenge_uris[${idx}]}" "${data}" | clean_json)"

        reqstatus="$(printf '%s\n' "${result}" | get_json_string_value status)"

        while [[ "${reqstatus}" = "pending" ]]; do
            sleep 1
            result="$(http_request GET "${challenge_uris[${idx}]}")"
            reqstatus="$(printf '%s\n' "${result}" | get_json_string_value status)"
            echo '---'
            echo "${reqstatus}"
        done

        if [[ "${reqstatus}" = "valid" ]]; then
            echo " + Challenge is valid!"
        else
            echo " - Challenge failed!"
            break
        fi

        idx=$((idx+1))
    done
}

_generate_private_key() {
    echo " + Generating private key..."
    openssl genrsa -out "${1}" 2048
}

_generate_csr() {
    prikey="${1}"
    shift
    csr="${1}"

    SUBJ="/CN=${FQDN}/"
    SAN="DNS:abcd.sunzhongmou.com"
    tmp_openssl_cnf="$(_mktemp)"
    cat "${OPENSSL_CNF}" > "${tmp_openssl_cnf}"
    printf "[SAN]\nsubjectAltName=%s" "${SAN}" >> "${tmp_openssl_cnf}"

    openssl req -new -sha256 -key "${prikey}" -out "${csr}" -subj "${SUBJ}" -reqexts SAN -config "${tmp_openssl_cnf}"
}

_sign_csr() {
    local csr="${1}"
    local newOrder="${2}"
    local accountKey="${3}"

    if { true >&3; } 2>/dev/null; then
        : # fd 3 looks OK
    else
        _exiterr "sign_csr: FD 3 not open"
    fi
    finalize="$(echo "${newOrder}" | get_json_string_value finalize)"

    # Finally request certificate from the acme-server and store it in cert-${timestamp}.pem and link from cert.pem
    echo " + Requesting certificate..."
    csr64="$( <<<"${csr}" openssl req -config "${OPENSSL_CNF}" -outform DER | urlbase64)"

    payload='{"csr": "'"${csr64}"'"}'
    payload64=$(printf '%s' "${payload}" | urlbase64)

    nonce="$(http_request HEAD "${CA_NEW_NONCE}" | grep -i ^Replay-Nonce: | awk -F ': ' '{print $2}' | tr -d '\n\r')"

    header='{"alg": "RS256", "jwk": {"e": "'"${pubExponent64}"'", "kty": "RSA", "n": "'"${pubMod64}"'"}}'
    protected='{"alg": "RS256", "kid": "'"${ACCOUNT_URL}"'", "url": "'"${finalize}"'", "nonce": "'"${nonce}"'"}'
    protected64="$(printf '%s' "${protected}" | urlbase64)"

    signed64="$(printf '%s' "${protected64}.${payload64}" | openssl dgst -sha256 -sign "${accountKey}" | urlbase64)"
    data='{"protected": "'"${protected64}"'", "payload": "'"${payload64}"'", "signature": "'"${signed64}"'"}'

    result="$(http_request POST "${finalize}" "${data}" | clean_json | get_json_string_value certificate)"

    crt="$(http_request GET "${result}")"

    # Try to load the certificate to detect corruption
    echo " + Checking certificate..."
    openssl x509 -text <<<"${crt}"

    echo "${crt}" >&3

    echo " + Done!"
}

_issue_domain() {
    local timestamp="$(date +%s)"

    accountkey="${CERTDIR}/account-key-${timestamp}.pem"
    privatekey="${CERTDIR}/private-${timestamp}.pem"
    csr="${CERTDIR}/${timestamp}.csr"
    crt_path="${CERTDIR}/cert-${timestamp}.pem"

    _generate_account_key "${accountkey}"
    _register_account "${accountkey}"
    accountkeyresult="$(_new_order "${accountkey}")"
    _build_deploy_args "${accountkeyresult}"
    _deploy_challenge
    _validate_pending_challenge "${accountkey}"
    _clean_challenge

    _generate_private_key "${privatekey}"
    _generate_csr "${privatekey}" "${csr}"
    _sign_csr "$(< "${csr}")" "$(echo ${accountkeyresult} | clean_json)" "${accountkey}" 3>"${crt_path}"

    tmpcert="$(_mktemp)"
    tmpchain="$(_mktemp)"
    awk '{print >out}; /----END CERTIFICATE-----/{out=tmpchain}' out="${tmpcert}" tmpchain="${tmpchain}" "${CERTDIR}/cert-${timestamp}.pem"
    mv "${CERTDIR}/cert-${timestamp}.pem" "${CERTDIR}/fullchain-${timestamp}.pem"
    cat "${tmpcert}" > "${CERTDIR}/cert-${timestamp}.pem"
    cat "${tmpchain}" > "${CERTDIR}/chain-${timestamp}.pem"
    rm "${tmpcert}" "${tmpchain}"

    # Update symlinks
    [[ "${privatekey}" = "privkey.pem" ]] || ln -sf "privkey-${timestamp}.pem" "${CERTDIR}/privkey.pem"

    ln -sf "chain-${timestamp}.pem" "${CERTDIR}/chain.pem"
    ln -sf "fullchain-${timestamp}.pem" "${CERTDIR}/fullchain.pem"
    ln -sf "cert-${timestamp}.csr" "${CERTDIR}/cert.csr"
    ln -sf "cert-${timestamp}.pem" "${CERTDIR}/cert.pem"

    echo "${timestamp}"
}

main() {
    FQDN="${1}"
    _issue_domain
}

main "${@-}"
