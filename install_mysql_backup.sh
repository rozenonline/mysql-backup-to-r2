#!/usr/bin/env bash
set -Eeuo pipefail

# ensure PATH contains /usr/local/bin for non-login shells & sudo secure_path
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
hash -r

# =================== 기본 설정(원하면 바꿔도 됨) ===================
AWS_PROFILE="r2-backup"                  # R2용 AWS CLI 프로필명
BACKUP_DIR="/root/backup"
BACKUP_BIN="/usr/local/bin/mysql-backup.sh"
MY_CNF_PATH="/root/.my.cnf"

# =================== 권한/OS 준비 ===================
if [[ $EUID -ne 0 ]]; then
  echo "[ERR] root 권한으로 실행하세요 (sudo 사용)."
  exit 1
fi

pkg_install() {
  (command -v dnf >/dev/null 2>&1 && dnf -y install "$@") \
  || (command -v yum >/dev/null 2>&1 && yum -y install "$@") \
  || (command -v apt >/dev/null 2>&1 && apt update -y && apt -y install "$@") \
  || (command -v apk >/dev/null 2>&1 && apk add --no-cache "$@") \
  || true
}

command -v curl >/dev/null 2>&1 || pkg_install curl unzip
command -v unzip >/dev/null 2>&1 || pkg_install unzip

# =================== 1) AWS CLI v2 설치 ===================
if ! command -v aws >/dev/null 2>&1; then
  echo "[INFO] AWS CLI v2 설치 중…"
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip -q awscliv2.zip
  ./aws/install
  popd >/dev/null
  rm -rf "$tmpdir"
else
  echo "[INFO] AWS CLI 이미 설치됨: $(aws --version)"
fi

# =================== 1-1) R2 접속정보 입력 ===================
echo
echo "=== Cloudflare R2 접속 정보 입력 ==="
read -rp "R2 Account ID (대시보드 R2 > Account ID): " R2_ACCOUNT_ID
read -rp "R2 Bucket 이름: " R2_BUCKET

HOST_SHORT="$(hostname -s)"
DEFAULT_BASENAME="mysql/${HOST_SHORT}/latest"
read -rp "R2 Object Key 베이스명(확장자 제외) [기본: ${DEFAULT_BASENAME}]: " R2_KEY_BASE_IN
R2_KEY_BASE="${R2_KEY_BASE_IN:-$DEFAULT_BASENAME}"
R2_KEY_GZ="${R2_KEY_BASE}.sql.gz"
R2_KEY_SHA="${R2_KEY_BASE}.sha256"

read -rp "AWS Access Key ID (R2): " AWS_KEY_ID
read -srp "AWS Secret Access Key (R2): " AWS_SECRET_KEY; echo
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

echo "[INFO] AWS CLI 프로필(${AWS_PROFILE}) 구성"
aws configure set aws_access_key_id "$AWS_KEY_ID" --profile "$AWS_PROFILE"
aws configure set aws_secret_access_key "$AWS_SECRET_KEY" --profile "$AWS_PROFILE"
aws configure set region "auto" --profile "$AWS_PROFILE"
aws configure set output "json" --profile "$AWS_PROFILE"
aws configure set s3.endpoint_url "$R2_ENDPOINT" --profile "$AWS_PROFILE"
aws configure set s3.addressing_style "path" --profile "$AWS_PROFILE"

# =================== 1-2) 연결 테스트 ===================
echo "[INFO] R2 연결 테스트(임시 업로드/삭제)…"
tmpf="$(mktemp)"
echo "r2 ok $(date -Iseconds)" > "$tmpf"
export AWS_S3_ADDRESSING_STYLE=path
export AWS_EC2_METADATA_DISABLED=true
aws --profile "$AWS_PROFILE" --endpoint-url "$R2_ENDPOINT" \
    s3 cp "$tmpf" "s3://${R2_BUCKET}/${R2_KEY_BASE}.install-test" --no-progress
aws --profile "$AWS_PROFILE" --endpoint-url "$R2_ENDPOINT" \
    s3 rm "s3://${R2_BUCKET}/${R2_KEY_BASE}.install-test"
rm -f "$tmpf"
echo "[INFO] R2 연결 OK"

# =================== 2) MySQL 자격증명 설정(선택) ===================
echo
echo "=== MySQL 자격증명 설정 ==="
echo " /root/.my.cnf 생성해서 비밀번호 저장하시겠습니까? (권장) [y/N]"
read -r CREATE_CNF
if [[ "${CREATE_CNF,,}" == "y" ]]; then
  read -rp "MySQL 사용자 (기본: root): " MYSQL_USER
  MYSQL_USER="${MYSQL_USER:-root}"
  read -rp "MySQL host (기본: 127.0.0.1): " MYSQL_HOST
  MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
  read -srp "MySQL 비밀번호: " MYSQL_PASS; echo

  # 비밀번호 안전 이스케이프 및 따옴표 감싸기
  # - my.cnf에서 #, ; 등이 값 안에 있으면 주석으로 오인될 수 있으므로 항상 작은따옴표로 감쌉니다.
  # - 내부의 작은따옴표는 '\'' 로 이스케이프
  esc_pw="$(printf "%s" "$MYSQL_PASS" | sed "s/'/'\"'\"'/g")"

  cat > "$MY_CNF_PATH" <<EOF
[client]
user=$MYSQL_USER
password='$esc_pw'
host=$MYSQL_HOST
# socket=/var/lib/mysql/mysql.sock
# port=3306
EOF
  chmod 600 "$MY_CNF_PATH"
  echo "[INFO] $MY_CNF_PATH 생성 완료 (특수문자 안전 처리)"
else
  echo "[INFO] ~/.my.cnf 생략: 소켓 인증(root) 또는 환경변수(MYSQL_USER/MYSQL_PWD) 사용 가능"
fi

# =================== 2-1) MAX_BACKUPS 입력 ===================
echo
while true; do
  read -rp "로컬에 보관할 '백업 세트' 최대 개수 (정수, 예: 10): " MAX_BACKUPS
  [[ "$MAX_BACKUPS" =~ ^[1-9][0-9]*$ ]] && break
  echo "숫자만 입력하세요 (1 이상)."
done

# =================== 2-2) 백업 스크립트 설치 ===================
echo "[INFO] 백업 스크립트 설치: $BACKUP_BIN"
install -d -m 700 "$BACKUP_DIR"

cat > "$BACKUP_BIN" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# ensure PATH contains /usr/local/bin for non-login shells & sudo secure_path
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
hash -r

# ================= [ 설정 ] =================
BACKUP_DIR="/root/backup"
LOCK_FILE="/var/lock/mysql-backup.lock"
MY_CNF="/root/.my.cnf"
MAX_BACKUPS=__MAX_BACKUPS__     # 최신 N개 세트만 유지(.sql.gz + .sha256)

# R2 업로드(마지막 백업만 유지: 고정 키로 덮어쓰기)
AWS_PROFILE="__AWS_PROFILE__"
R2_ACCOUNT_ID="__R2_ACCOUNT_ID__"
R2_BUCKET="__R2_BUCKET__"
R2_ENDPOINT="https://__R2_ACCOUNT_ID__.r2.cloudflarestorage.com"
R2_KEY_GZ="__R2_KEY_GZ__"
R2_KEY_SHA="__R2_KEY_SHA__"

# ================= [ 준비 ] =================
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
# 시작 시 혹시 남아있는 .sql 제거
find "$BACKUP_DIR" -type f -name "*.sql" -delete || true

# 중복 실행 방지
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "[ERR] 다른 백업이 실행 중입니다."; exit 1; }

# 에러 시 정리
cleanup_on_error() {
  echo "[ERR] 백업 중 오류 발생 ($(date -Iseconds))."
  [[ -n "${OUT_FILE:-}" && -f "$OUT_FILE" ]] && rm -f -- "$OUT_FILE"
  exit 1
}
trap cleanup_on_error ERR

# 타임스탬프/호스트
HOST="$(hostname -s)"
TS="$(date +%Y%m%d-%H%M)"
OUT_FILE="$BACKUP_DIR/${HOST}-mysqldump-${TS}.sql"
OUT_FILE_COMPRESSED="${OUT_FILE}.gz"
LOG_PREFIX="[${TS}]"

# ================= [ 인증 인자 ] =================
AUTH_ARGS=()
if [[ -f "$MY_CNF" ]]; then
  AUTH_ARGS=( --defaults-file="$MY_CNF" )
elif [[ -n "${MYSQL_USER:-}" ]]; then
  AUTH_ARGS=( -u"$MYSQL_USER" )
  export MYSQL_PWD="${MYSQL_PWD:-}"
else
  AUTH_ARGS=()
fi

# ================= [ 덤프 바이너리/옵션 ] =================
DUMP_BIN="$(command -v mariadb-dump || true)"
[[ -z "$DUMP_BIN" ]] && DUMP_BIN="$(command -v mysqldump || true)"
[[ -z "$DUMP_BIN" ]] && { echo "$LOG_PREFIX [ERR] mysqldump/mariadb-dump 없음"; exit 1; }

supports_opt() {
  "$DUMP_BIN" --help 2>/dev/null | grep -qE "(^|[[:space:]])${1}(=|\s|$)"
}

# ================= [ DB 목록 ] =================
DBS=$(mysql "${AUTH_ARGS[@]}" -N -e "SHOW DATABASES" \
  | grep -Ev '^(mysql|information_schema|performance_schema|sys)$' || true)

if [[ -z "${DBS:-}" ]]; then
  echo "$LOG_PREFIX [WARN] 백업할 DB 없음"
  exit 0
fi

echo "$LOG_PREFIX 시작: $HOST / 대상 DB: $(echo "$DBS" | tr '\n' ' ')"

# ================= [ 옵션 구성 ] =================
DUMP_OPTS="--single-transaction --quick --routines --events --triggers --skip-lock-tables"
supports_opt "--set-gtid-purged" && DUMP_OPTS+=" --set-gtid-purged=OFF"
supports_opt "--column-statistics" && DUMP_OPTS+=" --column-statistics=0"

# ================= [ 덤프 & 압축(스트리밍) ] =================
"$DUMP_BIN" "${AUTH_ARGS[@]}" $DUMP_OPTS --databases $DBS \
  | gzip -9 > "$OUT_FILE_COMPRESSED"

# 체크섬
sha256sum "$OUT_FILE_COMPRESSED" > "${OUT_FILE_COMPRESSED}.sha256"

# ================= [ 로컬 보관정책: 개수 기준만 적용 ] =================
# 최신순으로 .sql.gz 나열 → MAX_BACKUPS 개까지만 남기고 나머지와 그 sha256을 삭제
mapfile -t FILES < <(ls -1t "$BACKUP_DIR"/*.sql.gz 2>/dev/null || true)
if (( ${#FILES[@]} > MAX_BACKUPS )); then
  for f in "${FILES[@]:$MAX_BACKUPS}"; do
    rm -f -- "$f" "${f}.sha256"
  done
fi

# ================= [ R2 업로드: '마지막 백업'만 유지 ] =================
export AWS_S3_ADDRESSING_STYLE=path
export AWS_EC2_METADATA_DISABLED=true
aws --profile "$AWS_PROFILE" --endpoint-url "$R2_ENDPOINT" \
    s3 cp "$OUT_FILE_COMPRESSED" "s3://${R2_BUCKET}/${R2_KEY_GZ}" --no-progress
aws --profile "$AWS_PROFILE" --endpoint-url "$R2_ENDPOINT" \
    s3 cp "${OUT_FILE_COMPRESSED}.sha256" "s3://${R2_BUCKET}/${R2_KEY_SHA}" --no-progress

SIZE="$(du -h "$OUT_FILE_COMPRESSED" | awk '{print $1}')"
echo "$LOG_PREFIX 완료: $(basename "$OUT_FILE_COMPRESSED") (크기: $SIZE)"
SCRIPT_EOF

# 토큰 치환
sed -i "s|__AWS_PROFILE__|${AWS_PROFILE}|g" "$BACKUP_BIN"
sed -i "s|__R2_ACCOUNT_ID__|${R2_ACCOUNT_ID}|g" "$BACKUP_BIN"
sed -i "s|__R2_BUCKET__|${R2_BUCKET}|g" "$BACKUP_BIN"
sed -i "s|__MAX_BACKUPS__|${MAX_BACKUPS}|g" "$BACKUP_BIN"
ESC_KEY_GZ="$(printf '%s' "$R2_KEY_GZ" | sed -e 's/[\/&]/\\&/g')"
ESC_KEY_SHA="$(printf '%s' "$R2_KEY_SHA" | sed -e 's/[\/&]/\\&/g')"
sed -i "s|__R2_KEY_GZ__|${ESC_KEY_GZ}|g" "$BACKUP_BIN"
sed -i "s|__R2_KEY_SHA__|${ESC_KEY_SHA}|g" "$BACKUP_BIN"
chmod 700 "$BACKUP_BIN"

# =================== 3) 크론 시간 입력(시스템 타임존 기준) ===================
TZ_NAME="$( (timedatectl 2>/dev/null | awk -F': ' '/Time zone:/{print $2}' | awk '{print $1}') || true )"
if [[ -z "$TZ_NAME" ]]; then
  TZ_NAME="$(cat /etc/timezone 2>/dev/null || echo "$(date +%Z) (offset $(date +%z))")"
fi
echo
echo "=== 크론 시간 설정 ==="
echo "서버 시스템 타임존: ${TZ_NAME}"
echo "이 타임존 기준으로 백업 시간을 입력하세요 (형식 HH:MM, 예: 06:00)"
while true; do
  read -rp "백업 실행 시간(HH:MM): " HHMM
  if [[ "$HHMM" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    CRON_HOUR="${BASH_REMATCH[1]}"
    CRON_MIN="${BASH_REMATCH[2]}"
    break
  else
    echo "형식이 올바르지 않습니다. 예: 06:00"
  fi
done

# 기존 항목 제거 후 새로 등록
echo "[INFO] 크론 등록: 매일 ${CRON_HOUR}:${CRON_MIN} (${TZ_NAME})"
( crontab -l 2>/dev/null | grep -vF "$BACKUP_BIN" || true; \
  echo "${CRON_MIN} ${CRON_HOUR} * * * ${BACKUP_BIN} >> /var/log/mysql-backup.log 2>&1" ) | crontab -

echo
echo "[완료] 설치가 끝났습니다."
echo "- 수동 테스트: sudo ${BACKUP_BIN}"
echo "- 로컬 백업 위치: ${BACKUP_DIR}"
echo "- R2 업로드 키(항상 마지막 백업만 보관):"
echo "    s3://${R2_BUCKET}/${R2_KEY_GZ}"
echo "    s3://${R2_BUCKET}/${R2_KEY_SHA}"
echo "- 로그: /var/log/mysql-backup.log"
