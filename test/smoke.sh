#!/usr/bin/env bash
# Verification suite for churchcrm-docker.
#
# Brings the stack up from a clean state and exercises every function that does not
# need a human. Exits non-zero if any check fails or any log shows an error.
#
# Uses a throwaway project name, its own .env, and a high port so it cannot
# disturb a real deployment.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${PROJECT:-crmtest}"
PORT="${PORT:-18999}"
IMAGE="${IMAGE:-dvalin21/churchcrm:7.7.1-apache}"
# Deliberately awkward: quote, backslash, semicolon and dollar all have to
# survive .env -> container env -> Config.php -> mariadb client.
DB_PASS="TestPw0'quote\\and;dollar\$"

PASS=0; FAIL=0; FAILED_NAMES=()
c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_0=$'\033[0m'

ok()    { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$c_g" "$c_0" "$1"; }
bad()   { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s  %s\n' "$c_r" "$c_0" "$1"
          [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
head_() { printf '\n%s== %s ==%s\n' "$c_y" "$1" "$c_0"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

compose() { docker compose -p "$PROJECT" --env-file "$HERE/.env.test" -f "$HERE/docker-compose.yaml" "$@"; }

# Query helper. Uses MYSQL_PWD rather than -p so a password containing shell
# metacharacters cannot be mangled by the client or the shell.
dbq() { compose exec -T -e MYSQL_PWD="$DB_PASS" db mariadb -N -B -u churchcrm churchcrm -e "$1" 2>/dev/null | tr -d '\r'; }

# Wait for a service to report healthy. Compose omits non-running containers from
# `ps`, so ask for the service by name and treat "no such container" as not-yet.
wait_healthy() {
  local svc="$1" s i
  for i in $(seq 1 60); do
    s="$(compose ps -a --format '{{.Health}}' "$svc" 2>/dev/null | tr -d '\r\n ')"
    [ "$s" = "healthy" ] && return 0
    sleep 3
  done
  return 1
}

# ---------------------------------------------------------------- test env ----
head_ "Preparing isolated test environment"
TESTDIR="$(mktemp -d)"
cleanup() { compose down -v >/dev/null 2>&1; rm -rf "$TESTDIR" "$HERE/.env.test"; }
trap cleanup EXIT

cat > "$HERE/.env.test" <<EOF
MYSQL_DATABASE=churchcrm
MYSQL_USER=churchcrm
MYSQL_PASSWORD=$DB_PASS
MYSQL_ROOT_PASSWORD=$(printf '%s' "$DB_PASS" | base64 -w0)
CRM_BIND_ADDR=127.0.0.1
CRM_PORT=$PORT
CRM_PUBLIC_URL=https://crm.example.org/
CRM_ROOT_PATH=
CRM_SERVER_NAME=crm.example.org
CRM_TRUSTED_PROXY=172.16.0.0/12
CRM_IMAGE=$IMAGE
EOF
chmod 600 "$HERE/.env.test"
ok "test .env written (password has quote, backslash, semicolon, dollar)"

compose config --quiet && ok "compose file parses" || bad "compose file parses"

# ------------------------------------------------------------ static checks ----
head_ "Static validation"

for f in build.sh render-config.sh; do
  sh -n "$HERE/$f" && ok "$f is valid POSIX sh" || bad "$f is valid POSIX sh"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$HERE/build.sh" "$HERE/render-config.sh" && ok "shellcheck clean" || bad "shellcheck clean"
else
  printf '  %sSKIP%s  shellcheck not installed\n' "$c_y" "$c_0"
fi

# ------------------------------------------------------------------- image ----
head_ "Image"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "image $IMAGE exists"
else
  bad "image $IMAGE exists" "run ./build.sh first"
fi

check "image runs as non-root" "www-data" "$(docker image inspect -f '{{.Config.User}}' "$IMAGE" 2>/dev/null)"

if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v gcc cc make' >/dev/null 2>&1; then
  bad "no compiler toolchain in image"
else
  ok "no compiler toolchain in image"
fi

MISSING_EXT=""
for ext in mysqli pdo_mysql mbstring intl gd zip bcmath curl exif gettext; do
  docker run --rm --entrypoint php "$IMAGE" -m 2>/dev/null | grep -qix "$ext" || MISSING_EXT="$MISSING_EXT $ext"
done
check "required PHP extensions present" "" "$MISSING_EXT"

if docker run --rm --entrypoint test "$IMAGE" -f /var/www/html/Include/Config.php; then
  bad "image ships no Include/Config.php" "credentials would be baked in"
else
  ok "image ships no Include/Config.php"
fi

# --------------------------------------------------------- guard: empty pw ----
head_ "Configuration guard"
GUARD_OUT="$(docker run --rm --entrypoint /bin/sh \
  -v "$HERE/render-config.sh:/opt/churchcrm/render-config.sh:ro" \
  -e DB_SERVER_NAME=db -e DB_NAME=c -e DB_USER=c -e DB_PASSWORD= \
  -e URL=https://x.test/ "$IMAGE" \
  /opt/churchcrm/render-config.sh true 2>&1 || true)"
case "$GUARD_OUT" in
  *"DB_PASSWORD is required but empty"*) ok "empty DB_PASSWORD rejected with a clear error" ;;
  *) bad "empty DB_PASSWORD rejected with a clear error" "got: $GUARD_OUT" ;;
esac

# -------------------------------------------------------- lifecycle: clean ----
head_ "Clean install (down -v, up -d)"
compose down -v >/dev/null 2>&1
if compose up -d >"$TESTDIR/up.log" 2>&1; then ok "compose up -d"
else bad "compose up -d" "$(tail -5 "$TESTDIR/up.log")"; fi

wait_healthy db  && ok "db healthy"   || bad "db healthy"
wait_healthy crm && ok "crm healthy"  || bad "crm healthy"

# ------------------------------------------------------------- app serving ----
head_ "Application"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
{ [ "$CODE" = "302" ] || [ "$CODE" = "200" ]; } \
  && ok "GET / responds ($CODE)" || bad "GET / responds" "got ${CODE:-000}"

curl -s -L -o "$TESTDIR/landing.html" "http://127.0.0.1:$PORT/" >/dev/null 2>&1
grep -qi "<title>ChurchCRM: Login" "$TESTDIR/landing.html" \
  && ok "login page renders" || bad "login page renders"
grep -qi "/setup" "$TESTDIR/landing.html" \
  && bad "no setup wizard in the flow" || ok "no setup wizard in the flow"

CFG="$(compose exec -T crm cat /var/www/html/Include/Config.php 2>/dev/null)"
echo "$CFG" | grep -q "sSERVERNAME = 'db'" && ok "Config.php DB host" || bad "Config.php DB host"
echo "$CFG" | grep -q "URL\[0\] = 'https://crm.example.org/'" && ok "Config.php public URL" || bad "Config.php public URL"

LINT="$(compose exec -T crm php -l /var/www/html/Include/Config.php 2>&1)"
case "$LINT" in *"No syntax errors"*) ok "Config.php is valid PHP despite special chars" ;;
  *) bad "Config.php is valid PHP" "$LINT" ;; esac

# ------------------------------------------------------------ schema/admin ----
head_ "Schema and admin account"
TABLES="$(dbq "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='churchcrm';")"
{ [ "${TABLES:-0}" -gt 20 ] 2>/dev/null; } && ok "schema created automatically ($TABLES tables)" \
  || bad "schema created automatically" "only ${TABLES:-0} tables"

check "admin account exists and forces password change" "Admin:1:1" \
  "$(dbq "SELECT CONCAT(usr_UserName,':',usr_Admin,':',usr_NeedPasswordChange) FROM user_usr LIMIT 1;")"

# ------------------------------------------------------ reverse proxy logic ----
head_ "Reverse proxy handling"
curl -s -o /dev/null -H 'X-Forwarded-For: 198.51.100.77' "http://127.0.0.1:$PORT/" >/dev/null 2>&1
sleep 2
compose logs crm --since 30s 2>&1 | grep -q '198.51.100.77.*"GET / ' \
  && ok "X-Forwarded-For rewritten into REMOTE_ADDR" \
  || bad "X-Forwarded-For rewritten into REMOTE_ADDR" "client IP missing from logs"

curl -s -o /dev/null "http://127.0.0.1:$PORT/" >/dev/null 2>&1
sleep 2
compose logs crm --since 10s 2>&1 | grep '"GET / ' | grep -qv '198.51.100.77' \
  && ok "request without the header is not rewritten" \
  || bad "request without the header is not rewritten"

curl -s -D "$TESTDIR/hdr.txt" -o /dev/null -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$PORT/" >/dev/null 2>&1
grep -qi "set-cookie:.*secure" "$TESTDIR/hdr.txt" \
  && ok "Secure cookie set when X-Forwarded-Proto: https" \
  || bad "Secure cookie set when X-Forwarded-Proto: https" "$(grep -i set-cookie "$TESTDIR/hdr.txt" | head -2)"

check "mod_remoteip loaded" "1" "$(compose exec -T crm apache2ctl -M 2>/dev/null | grep -c remoteip_module)"

# ------------------------------------------------------------ persistence ----
head_ "Persistence"
MARK="persist-$RANDOM"
dbq "CREATE TABLE IF NOT EXISTS _smoke (v VARCHAR(32)); INSERT INTO _smoke VALUES ('$MARK');" >/dev/null
check "seed row written" "$MARK" "$(dbq 'SELECT v FROM _smoke LIMIT 1;')"

compose restart >/dev/null 2>&1
wait_healthy db && wait_healthy crm && ok "both healthy again after restart" || bad "both healthy again after restart"
check "data survives restart" "$MARK" "$(dbq 'SELECT v FROM _smoke LIMIT 1;')"

compose up -d --force-recreate crm >/dev/null 2>&1
wait_healthy crm && ok "crm healthy after recreation" || bad "crm healthy after recreation"
check "data survives container recreation (image upgrade path)" "$MARK" "$(dbq 'SELECT v FROM _smoke LIMIT 1;')"

compose exec -T crm test -f /var/www/html/Include/Config.php \
  && ok "Config.php regenerated after recreation" \
  || bad "Config.php regenerated after recreation" "would fall back to the wizard"

CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
{ [ "$CODE" = "302" ] || [ "$CODE" = "200" ]; } && ok "app serves after upgrade ($CODE)" \
  || bad "app serves after upgrade" "got ${CODE:-000}"

compose exec -T --user www-data crm sh -c 'touch /var/www/html/Images/Person/.w && rm /var/www/html/Images/Person/.w' >/dev/null 2>&1 \
  && ok "www-data can write to persisted Images volume" \
  || bad "www-data can write to persisted Images volume"

# ---------------------------------------------------------- backup/restore ----
head_ "Backup and restore"
compose exec -T -e MYSQL_PWD="$DB_PASS" db mariadb-dump -u churchcrm churchcrm > "$TESTDIR/dump.sql" 2>/dev/null
{ [ -s "$TESTDIR/dump.sql" ] && grep -q "CREATE TABLE" "$TESTDIR/dump.sql"; } \
  && ok "mariadb-dump produces a usable dump" || bad "mariadb-dump produces a usable dump"

dbq "DROP TABLE IF EXISTS _smoke;" >/dev/null
check "table dropped before restore" "0" \
  "$(dbq "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='churchcrm' AND table_name='_smoke';")"

if compose exec -T -e MYSQL_PWD="$DB_PASS" db mariadb -u churchcrm churchcrm < "$TESTDIR/dump.sql" 2>"$TESTDIR/restore.err"; then
  ok "restore replays cleanly"
else
  bad "restore replays cleanly" "$(tail -3 "$TESTDIR/restore.err")"
fi
check "restored data matches" "$MARK" "$(dbq 'SELECT v FROM _smoke LIMIT 1;')"

# --------------------------------------------------------- db resilience ----
head_ "Resilience"
compose stop db >/dev/null 2>&1
sleep 3
compose up -d db >/dev/null 2>&1
wait_healthy db && ok "db recovers after restart" || bad "db recovers after restart"

for _ in $(seq 1 30); do
  C="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
  { [ "$C" = "302" ] || [ "$C" = "200" ]; } && break
  sleep 3
done
{ [ "$C" = "302" ] || [ "$C" = "200" ]; } && ok "app reconnects to db ($C)" \
  || bad "app reconnects to db" "got ${C:-000}"

# ----------------------------------------------------------- log scanning ----
head_ "Log scan"
DBLOG="$(compose logs db --since 1h 2>&1)"
APPLOG="$(compose logs crm --since 1h 2>&1)"
BOTH="$(printf '%s\n%s\n' "$APPLOG" "$DBLOG")"

HITS="$(printf '%s\n' "$BOTH" | grep -Ei 'PHP Fatal|PHP Parse error|PHP Warning|PHP Notice|Uncaught|Segmentation fault|panic:|AH00558|AH00526' || true)"
[ -z "$HITS" ] && ok "no PHP fatals/warnings or Apache config errors in logs" \
  || bad "no PHP fatals/warnings or Apache config errors in logs" "$(printf '%s' "$HITS" | head -5)"

printf '%s\n' "$APPLOG" | grep -qi 'AH00558' \
  && bad "ServerName set (no AH00558)" || ok "ServerName set (no AH00558)"

printf '%s' "$BOTH" | grep -qF "$DB_PASS" \
  && bad "database password absent from logs" || ok "database password absent from logs"

printf '%s' "$BOTH" | grep -qi 'the generated password' \
  && bad "no plaintext passwords in mariadb startup log" || ok "no plaintext passwords in mariadb startup log"

APACHE_ERR="$(compose exec -T crm sh -c 'tail -50 /var/log/apache2/error.log 2>/dev/null' || true)"
printf '%s' "$APACHE_ERR" | grep -qiE 'PHP Fatal|PHP Parse|PHP Warning' \
  && bad "apache error.log clean of PHP errors" \
  || ok "apache error.log clean of PHP errors"

# Config.php holds the database password; assert it is not world- or group-readable.
CPERMS="$(compose exec -T crm stat -c '%a' /var/www/html/Include/Config.php 2>/dev/null | tr -d '\r')"
case "$CPERMS" in
  600|400) ok "Config.php not group/world readable (mode $CPERMS)" ;;
  *) bad "Config.php not group/world readable" "mode ${CPERMS:-?} (expected 600)" ;;
esac

# Any HTTP 5xx during the run means a broken request path.
FIVE_XX="$(compose logs crm --since 1h 2>&1 | grep -E '" [5][0-9][0-9] ' || true)"
[ -z "$FIVE_XX" ] && ok "no HTTP 5xx responses logged" \
  || bad "no HTTP 5xx responses logged" "$(printf '%s' "$FIVE_XX" | head -3)"

# ------------------------------------------------------------ log rotation ----
head_ "Log rotation configured"
{ [ "$(compose config 2>/dev/null | grep -c 'max-size')" -ge 2 ]; } \
  && ok "json-file rotation set on both services" || bad "json-file rotation set on both services"

# ----------------------------------------------------------------- summary ----
head_ "Summary"
printf '  passed: %d\n  failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failing checks:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '   - %s\n' "$n"; done
  exit 1
fi
printf '\n  %sall checks passed%s\n' "$c_g" "$c_0"
exit 0