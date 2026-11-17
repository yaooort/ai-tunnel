#!/bin/bash
# Deliberately produces test secrets only into AppModel's captured pipe.
set -eu
config_file=$2
runtime_dir=$(dirname "$config_file")
mode=${AI_TUNNEL_HARNESS_MODE:-connect}
token_file=$(sed -n 's/^auth.tokenSource.file.path = "\(.*\)"$/\1/p' "$config_file")
test_token=$(cat "$token_file")
trap 'exit 0' TERM INT
if [ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ]; then
  printf '%s\n' 'isolated failure: inherited proxy environment was not cleared'
  exit 43
fi

authenticated() { printf '%s\n' '[service] login to server success, get run id [isolated-test]'; }
connected() {
  authenticated
  printf '%s\n' '[proxy] [ai-http2] start proxy success'
  printf 'isolated log: token=%s password=TEST_PASSWORD_VALUE\n' "$test_token"
}

case "$mode" in
  crash) exit 42 ;;
  login-only) authenticated ;;
  proxy-error)
    authenticated
    printf '%s\n' '[proxy] [ai-http2] start error: port already used'
    ;;
  restart-once)
    count_file="$runtime_dir/fake-attempts"
    attempt=0
    if [ -f "$count_file" ]; then attempt=$(cat "$count_file"); fi
    attempt=$((attempt + 1))
    printf '%s\n' "$attempt" > "$count_file"
    if [ "$attempt" = 1 ]; then
      printf '%s\n' 'isolated child will exit for restart verification'
      exit 42
    fi
    connected
    ;;
  reconnect)
    connected
    sleep 0.3
    printf '%s\n' '[control] control connection closed'
    sleep 0.4
    connected
    ;;
  *) connected ;;
esac
while :; do sleep 0.1; done
