# mysql-backup-to-r2

자동으로 **MySQL/MariaDB** 데이터베이스를 백업하고\
**Cloudflare R2** 스토리지에 업로드하는 설치 스크립트입니다.

- 로컬에 날짜별 `.sql.gz` + `.sha256` 보관\
- 최신 N개 세트만 유지 (사용자가 지정)\
- R2에는 항상 같은 키(`latest.sql.gz`)로 업로드 → 마지막 백업만 유지\
- cron에 자동 등록 (사용자가 입력한 HH:MM에 매일 실행)\
- 설치 과정에서 AWS CLI + R2 프로필 자동 설정

---

## 요구사항

- Linux 서버 (테스트: Rocky/Alma/RHEL, Ubuntu, Debian, Alpine)\
- root 권한 (sudo 가능)\
- Cloudflare R2 계정 및 Access Key\
- MySQL/MariaDB 클라이언트 (`mysql`, `mysqldump`/`mariadb-dump`)

---

## 설치 방법

```bash
git clone https://github.com/yourname/mysql-backup-to-r2.git
cd mysql-backup-to-r2
chmod +x install_mysql_backup.sh
sudo ./install_mysql_backup.sh
```

설치 스크립트가 자동으로 진행합니다:

1.  AWS CLI 설치/구성 (Cloudflare R2 Access Key 입력)
2.  R2 연결 테스트
3.  MySQL 접속정보 설정 (`/root/.my.cnf`)
4.  로컬 보관 개수(MAX_BACKUPS) 입력
5.  cron 실행 시간(HH:MM, 서버 타임존 기준) 입력
6.  백업 스크립트(`/usr/local/bin/mysql-backup.sh`) 생성 및 등록

---

## 수동 실행

```bash
sudo /usr/local/bin/mysql-backup.sh
```

성공하면 `/root/backup` 아래에 백업 파일이 생깁니다:

    /root/backup/
    ├── server1-mysqldump-20250824-0600.sql.gz
    ├── server1-mysqldump-20250824-0600.sql.gz.sha256
    ...

---

## 동작 방식

- **로컬 보관**
  - `.sql.gz`와 `.sha256` 파일이 쌍으로 저장됨
  - 사용자가 입력한 `MAX_BACKUPS` 개까지만 최신 세트 보관\
  - 오래된 파일은 자동 삭제
- **R2 업로드**
  - 항상 같은 키(`mysql/<host>/latest.sql.gz`)로 업로드
  - 기존 파일은 덮어쓰기 → R2에는 "마지막 백업"만 남음
- **cron**
  - 설치 시 입력한 HH:MM (서버 타임존 기준)에 매일 자동 실행

---

## MySQL 접속정보 (`/root/.my.cnf`)

```ini
[client]
user=root
password='P@ssw0rd#2025!'
host=127.0.0.1
```

- 비밀번호는 자동으로 `'작은따옴표'`로 감싸져서 저장됩니다.\
- `#`, `;`, 공백, 특수문자 모두 안전하게 처리됩니다.

---

## 로그 확인

```bash
tail -n 100 /var/log/mysql-backup.log
```

---

## 복구 방법

```bash
# sha256 체크
sha256sum -c /root/backup/server1-mysqldump-20250824-0600.sql.gz.sha256

# 복구
gunzip -c /root/backup/server1-mysqldump-20250824-0600.sql.gz | mysql --defaults-file=/root/.my.cnf
```

---

## TODO / 개선 아이디어

- [ ] Telegram/Slack 알림 (성공/실패 시)
- [ ] 업로드 실패 시 재시도(backoff)
- [ ] Read Replica에서 백업하기 (운영 DB 부하 최소화)
- [ ] Docker 이미지 배포

---

## 라이선스

MIT License
