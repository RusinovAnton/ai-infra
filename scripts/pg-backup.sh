#!/usr/bin/env bash
# Encrypted backup of the gateway's Postgres, plus a rehearsed restore.
#
#   ./pg-backup.sh            dump + encrypt into backups/
#   ./pg-backup.sh --verify   dump, restore into a scratch DB, assert a key
#                             issued before the dump still authenticates
#
# Losing this database means losing every virtual key and all spend
# attribution, and re-issuing keys to every user. A restore you have not
# performed is not a backup — which is why --verify exists and why it belongs in
# the cron alongside the plain dump, not in a runbook nobody opens.
#
# Cron (weekly verify, daily dump):
#   30 3 * * * /path/to/ai-infra/scripts/pg-backup.sh          >> /tmp/pg-backup.log 2>&1
#   30 4 * * 0 /path/to/ai-infra/scripts/pg-backup.sh --verify  >> /tmp/pg-backup.log 2>&1
set -euo pipefail
. "$(dirname "$0")/common.sh"

VERIFY=0; AUDIT=0
case "${1:-}" in
  --verify) VERIFY=1 ;;
  --audit)  AUDIT=1 ;;
  "")       ;;
  *)        echo "usage: $(basename "$0") [--verify|--audit]" >&2; exit 2 ;;
esac

[ -f "$GATEWAY_DIR/.env" ] || die "missing gateway/.env"
set -a; . "$GATEWAY_DIR/.env"; set +a
: "${BACKUP_PASSPHRASE:=}"

BACKUP_DIR="$REPO_ROOT/backups"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RAW="$BACKUP_DIR/litellm-$STAMP.dump"

# ------------------------------------------------------------ audit

# --verify only ever checks the artifact it just wrote, with the passphrase it
# just used — self-consistent by construction, so it cannot notice that OLDER
# artifacts are no longer decryptable. Rotate BACKUP_PASSPHRASE and every
# retained dump silently becomes rubbish; with 14-day retention you would have
# no working backup and no warning. This mode is the missing check.
if [ "$AUDIT" = 1 ]; then
  [ -n "$BACKUP_PASSPHRASE" ] || die "BACKUP_PASSPHRASE not set — nothing to audit against"
  shopt -s nullglob
  arts=("$BACKUP_DIR"/litellm-*.dump.enc)
  [ ${#arts[@]} -gt 0 ] || { log "no encrypted artifacts in $BACKUP_DIR"; exit 0; }
  bad_count=0
  for f in "${arts[@]}"; do
    # PGDMP is pg_dump's custom-format magic. See the decrypt note below for why
    # openssl's exit code cannot be trusted here.
    if [ "$(openssl enc -d -aes-256-ctr -pbkdf2 -iter 600000 \
              -pass env:BACKUP_PASSPHRASE -in "$f" 2>/dev/null | head -c 5)" = "PGDMP" ]; then
      printf '  ok            %s\n' "$(basename "$f")"
    else
      printf '  UNRECOVERABLE %s\n' "$(basename "$f")"; bad_count=$((bad_count+1))
    fi
  done
  [ "$bad_count" -eq 0 ] \
    && { log "all ${#arts[@]} artifact(s) decrypt with the current passphrase"; exit 0; } \
    || die "$bad_count of ${#arts[@]} artifact(s) cannot be decrypted — passphrase rotated without re-encrypting, or corruption"
fi

cd "$GATEWAY_DIR"

# ------------------------------------------------------------ canary (verify)

# Issued BEFORE the dump, so it lands inside the artifact we will later decrypt
# and restore. Doing it the other way round forces a second, separate dump to
# rehearse against — which proves pg_restore works but says nothing about
# whether the encrypted file on disk is recoverable. A wrong passphrase or a
# silently corrupted encryption step would still report success.
if [ "$VERIFY" = 1 ]; then
  K="$(curl -s -X POST "$GW/key/generate" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        -H 'Content-Type: application/json' \
        -d '{"models":["coder"],"metadata":{"user":"pg-backup-rehearsal"}}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("key",""))' 2>/dev/null || true)"
  [ -n "$K" ] || die "could not issue a canary key — is the gateway up?"
  log "canary key issued; it must survive into the restored copy"
fi

log "dumping litellm"
# Custom format so pg_restore can be selective, and so the restore rehearsal
# below exercises the same path a real recovery would.
pgx pg_dump -U litellm -d litellm -Fc > "$RAW"
chmod 600 "$RAW"
[ -s "$RAW" ] || die "dump is empty"
log "dump: $(du -h "$RAW" | cut -f1)"

# ------------------------------------------------------------ encrypt

if [ -n "$BACKUP_PASSPHRASE" ]; then
  log "encrypting"
  openssl enc -aes-256-ctr -pbkdf2 -iter 600000 -salt \
    -pass env:BACKUP_PASSPHRASE -in "$RAW" -out "$RAW.enc"
  chmod 600 "$RAW.enc"; rm -f "$RAW"
  log "encrypted: $RAW.enc"
  log "decrypt with: openssl enc -d -aes-256-ctr -pbkdf2 -iter 600000 -pass env:BACKUP_PASSPHRASE -in <file> | docker compose exec -T litellm-db pg_restore -U litellm -d litellm  (or pg_restore directly if you have PGHOST set)"
else
  # Not silently skipped: an unencrypted dump of every virtual key sitting on
  # the office machine is a different risk posture than the design assumes.
  log "WARNING: BACKUP_PASSPHRASE not set in gateway/.env — dump left UNENCRYPTED at $RAW"
fi

# ------------------------------------------------------------ rehearse restore

if [ "$VERIFY" = 1 ]; then
  # Rehearse against THE ARTIFACT ON DISK — decrypting it first if it is
  # encrypted. This is the only version of this check that means anything: it
  # exercises the exact bytes a real recovery would start from, including the
  # decrypt step, rather than a convenience dump taken alongside them.
  ARTIFACT="$RAW"; [ -f "$RAW.enc" ] && ARTIFACT="$RAW.enc"
  log "restore rehearsal from the artifact: $(basename "$ARTIFACT")"

  REHEARSE="$(mktemp)"
  trap 'rm -f "$REHEARSE"' EXIT
  if [ "$ARTIFACT" = "$RAW.enc" ]; then
    openssl enc -d -aes-256-ctr -pbkdf2 -iter 600000 \
      -pass env:BACKUP_PASSPHRASE -in "$ARTIFACT" -out "$REHEARSE" \
      || die "DECRYPT FAILED — openssl could not read $ARTIFACT at all."
    # openssl's exit code is NOT sufficient here. -aes-256-ctr is a raw stream
    # cipher with no MAC and no padding, so a WRONG passphrase decrypts to
    # garbage and still exits 0 — verified. The only cheap integrity signal is
    # the plaintext's own header: pg_dump custom format begins with "PGDMP".
    # Without this check a wrong BACKUP_PASSPHRASE is discovered at recovery
    # time, which is the worst possible moment.
    magic="$(head -c 5 "$REHEARSE" 2>/dev/null || true)"
    [ "$magic" = "PGDMP" ] \
      || die "DECRYPT PRODUCED GARBAGE — header is '$magic', expected 'PGDMP'. Wrong BACKUP_PASSPHRASE, or the artifact is corrupt. This backup is NOT recoverable."
    log "decrypted and header verified (PGDMP)"
  else
    cp "$ARTIFACT" "$REHEARSE"
  fi

  pgx psql -qU litellm -d postgres \
    -c 'DROP DATABASE IF EXISTS restore_test;' -c 'CREATE DATABASE restore_test;' >/dev/null
  pgx pg_restore -U litellm -d restore_test --no-owner < "$REHEARSE" >/dev/null 2>&1 || true

  # The hash, not the key: LiteLLM stores keys hashed, so this is what a real
  # recovery would have to be able to authenticate against.
  hash="$(printf '%s' "$K" | sha256_hex)"
  found="$(pgx psql -tAqU litellm -d restore_test \
    -c "SELECT count(*) FROM \"LiteLLM_VerificationToken\" WHERE token = '$hash';" 2>/dev/null | tr -d '[:space:]')"
  tables="$(pgx psql -tAqU litellm -d restore_test \
    -c "select count(*) from information_schema.tables where table_schema='public';" 2>/dev/null | tr -d '[:space:]')"

  pgx psql -qU litellm -d postgres \
    -c 'DROP DATABASE IF EXISTS restore_test;' >/dev/null
  curl -s -X POST "$GW/key/delete" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' -d "{\"keys\":[\"$K\"]}" >/dev/null || true

  [ "${found:-0}" -ge 1 ] \
    && log "RESTORE VERIFIED: canary key recovered from the on-disk artifact (${tables} tables)" \
    || die "RESTORE FAILED: the canary key did not survive — this backup would not recover the tailnet's key material"
fi

# Keep 14 days. Adjust once there is an offsite copy; a backup that only exists
# on the machine it protects is not one.
find "$BACKUP_DIR" -name 'litellm-*.dump*' -mtime +14 -delete 2>/dev/null || true
log "done"
