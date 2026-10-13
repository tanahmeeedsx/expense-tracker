# Deployment Guide: AWS EC2 + Docker Compose + S3 Backup + Docker Scout

Ei guide follow korle Expense Tracker (React + Express + MongoDB) ek EC2 instance e chalbe, MongoDB backup S3 e jabe, ar image gula Docker Scout diye scan hobe.

## 1. Architecture

```
Internet
   │  :80 (only open app port)
   ▼
┌───────────────────────── EC2 (Ubuntu 24.04) ─────────────────────────┐
│                                                                       │
│  frontend_net (custom bridge)        backend_net (custom bridge,      │
│                                      internal = no internet access)  │
│  ┌──────────────┐                                                     │
│  │ nginx :8080  │──────────────────►┌──────────────┐   ┌───────────┐  │
│  │ (non-root)   │   /api/*          │ backend :5000│──►│ mongo     │  │
│  └──────────────┘                   │ (non-root)   │   │ :27017    │  │
│                                     └──────────────┘   └─────┬─────┘  │
│                                                              │        │
│        host cron ── backup.sh ── mongodump (docker exec) ────┘        │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ aws s3 cp (EC2 IAM role, no access keys)
                               ▼
                    S3 bucket (private, encrypted, versioned, 30-day lifecycle)
```

Network design:

| Network | Type | Kara ache |
|---|---|---|
| `expense_frontend_net` | custom bridge | nginx (internet-facing side) |
| `expense_backend_net` | custom bridge, `internal: true` | nginx, backend, mongo. Outside theke reach kora jay na, internet access nai |

Mongo ar backend er kono port host e publish kora hoyni. Sudhu nginx er `80` port open.

## 2. Ki ki change hoyeche

| File | Change |
|---|---|
| `backend/Dockerfile` | 2-stage (`deps` → `runtime`), non-root `node` user, healthcheck, `apk upgrade`, Node 24 LTS (Node 20 EOL hoye geche) |
| `frontend/Dockerfile` | 3-stage (`deps` → `build` → `runtime`), `nginx-unprivileged` (non-root, port 8080), healthcheck |
| `frontend/nginx/default.conf` | port 8080, `server_tokens off`, security headers, `/healthz` |
| `docker-compose.yml` | 2 custom bridge network, Mongo auth + least-privilege app user, healthcheck + `depends_on: service_healthy`, `read_only`, `cap_drop: ALL`, `no-new-privileges`, memory limit, log rotation |
| `mongo-init/01-create-app-user.sh` | prothom start e `readWrite` only app user create kore |
| `.env.example` | password, S3 bucket, region, port config |
| `scripts/backup.sh` / `restore.sh` | mongodump → S3 stream, restore from S3 |
| `scripts/scout-scan.sh` / `deploy.sh` | Docker Scout scan (CRITICAL/HIGH fail), one-command deploy |

> Tip: `backend/` ar `frontend/` e `package-lock.json` nai. Local e `npm install` chalie lockfile toiri hobe, commit koro. Tahole Dockerfile automatically `npm ci` use korbe (reproducible build).

## 3. AWS setup

Region: Bangladesh theke latency kom hobe `ap-southeast-1` (Singapore) ba `ap-south-1` (Mumbai). Guide e `ap-southeast-1` dhorsi.

### 3.1 S3 bucket (AWS CLI, ba CloudShell theke)

```bash
export AWS_REGION=ap-southeast-1
export BUCKET=expense-tracker-backup-$(aws sts get-caller-identity --query Account --output text)

# 1) bucket create
aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# 2) public access fully blocked
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 3) versioning (accidental delete/overwrite theke bachay)
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

# 4) default encryption
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# 5) lifecycle: 30 din por purono backup delete
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [{
    "ID": "expire-old-backups",
    "Status": "Enabled",
    "Filter": {"Prefix": "mongodb/"},
    "Expiration": {"Days": 30},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 7},
    "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}
  }]
}'

echo "Bucket: $BUCKET"   # .env e S3_BACKUP_BUCKET e eta boshabe
```

### 3.2 IAM role for EC2 (access key chara S3 access)

```bash
cat > trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat > s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${BUCKET}"
    },
    {
      "Sid": "ReadWriteBackups",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/mongodb/*"
    }
  ]
}
EOF

aws iam create-role --role-name expense-tracker-ec2-role --assume-role-policy-document file://trust.json
aws iam put-role-policy --role-name expense-tracker-ec2-role --policy-name s3-backup-access --policy-document file://s3-policy.json
aws iam create-instance-profile --instance-profile-name expense-tracker-ec2-profile
aws iam add-role-to-instance-profile --instance-profile-name expense-tracker-ec2-profile --role-name expense-tracker-ec2-role
```

Role ta sudhu oi bucket er `mongodb/` prefix e put/get korte pare. Delete permission nai (cleanup lifecycle rule kore).

### 3.3 EC2 instance launch (Console)

| Setting | Value |
|---|---|
| AMI | Ubuntu Server 24.04 LTS (x86_64) |
| Instance type | `t3.small` (2 GB RAM). `t3.micro` e build slow/OOM hote pare, nile swap add koro (4.4) |
| Key pair | notun create koro, `.pem` file safe rakho |
| Storage | 20 GB gp3, **Encrypted** |
| IAM instance profile | `expense-tracker-ec2-profile` (Advanced details e) |
| Metadata version | **V2 only** (Advanced details e) |

Security Group inbound rules:

| Port | Source | Karon |
|---|---|---|
| 22 (SSH) | **My IP** only | admin access |
| 80 (HTTP) | 0.0.0.0/0 | web app |

`27017` (Mongo) ar `5000` (API) kokhono open korba na.

Launch er por **Elastic IP** allocate kore instance e associate koro, jate IP change na hoy (ar `CORS_ORIGIN` stable thake).

## 4. Server setup

```bash
chmod 400 your-key.pem
ssh -i your-key.pem ubuntu@<ELASTIC_IP>
```

### 4.1 System update + Docker Engine

```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get install -y ca-certificates curl git unzip

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker $USER
exit    # logout kore abar ssh korle docker group apply hobe
```

Abar SSH kore check koro:

```bash
docker --version && docker compose version
```

### 4.2 AWS CLI v2

```bash
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install
aws --version
aws sts get-caller-identity      # Arn e "assumed-role/expense-tracker-ec2-role" dekhte pawa uchit
```

### 4.3 Docker Scout CLI

```bash
curl -sSfL https://raw.githubusercontent.com/docker/scout-cli/main/install.sh -o /tmp/install-scout.sh
sh /tmp/install-scout.sh
docker login -u <your-dockerhub-username>     # password er jaygay Docker Hub Personal Access Token use koro
docker scout version
```

Scout CLI chalate Docker Hub account lagbe. Plan limit/feature Docker er docs e check kore nio.

### 4.4 (Optional) Swap, jodi `t3.micro` use koro

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 5. Deploy

### 5.1 Notun file gula GitHub repo te push koro (local machine theke)

Ei zip er file gula tomar `expense-tracker` repo te copy kore:

```bash
git add .
git commit -m "feat: multi-stage docker, custom networks, S3 backup, scout scan"
git push
```

### 5.2 Server e clone + .env

```bash
git clone https://github.com/tanahmeeedsx/expense-tracker.git
cd expense-tracker

cp .env.example .env
chmod 600 .env

# strong password generate kore .env e boshao
openssl rand -hex 24     # 2 bar chalao: ekta root, ekta app password

nano .env
```

`.env` e ja change korte hobe:

| Variable | Value |
|---|---|
| `MONGO_ROOT_PASSWORD` | random hex |
| `MONGO_APP_PASSWORD` | random hex (root er theke alada) |
| `CORS_ORIGIN` | `http://<ELASTIC_IP>` |
| `HTTP_PORT` | `80` |
| `S3_BACKUP_BUCKET` | step 3.1 er `$BUCKET` |
| `AWS_REGION` | `ap-southeast-1` |

### 5.3 Build, scan, start

```bash
chmod +x scripts/*.sh mongo-init/*.sh

docker compose config -q && echo "compose file OK"
./scripts/deploy.sh
```

`deploy.sh` ja kore: `git pull` → `docker compose build --pull` → **Docker Scout scan** → `docker compose up -d`.

Manually korte chaile:

```bash
docker compose build --pull
./scripts/scout-scan.sh
docker compose up -d
docker compose ps
```

## 6. Verify

```bash
docker compose ps                          # 3 ta service "healthy" hote hobe
curl -s http://localhost/api/health        # {"status":"ok", "mongoState":1, ...}
docker network ls | grep expense           # 2 ta custom bridge network
docker network inspect expense_backend_net --format '{{.Internal}}'   # true
docker compose logs -f backend             # "Connected to MongoDB"
```

Browser e kholo: `http://<ELASTIC_IP>`, "Seed demo data" diye test koro.

Security check (laptop theke): `nmap -Pn -p 22,80,5000,27017 <ELASTIC_IP>` → sudhu `22` ar `80` open dekhabe.

## 7. Docker Scout

```bash
./scripts/scout-scan.sh                                     # full scan (deploy.sh o eta chalay)
docker scout quickview local://expense-tracker-backend:latest
docker scout cves --only-severity critical,high local://expense-tracker-frontend:latest
docker scout recommendations local://expense-tracker-backend:latest   # better base image suggestion
```

- Script ta **fixable CRITICAL/HIGH** CVE pele exit code `2` diye deploy ta stop kore dey.
- Gate severity change korte: `SCOUT_FAIL_SEVERITY=critical ./scripts/scout-scan.sh`
- Fail korle: `docker compose build --pull --no-cache` diye base image update kore abar scan koro, ba `recommendations` er suggestion onujayi base image tag bump koro.
- `mongo:7.0` er scan sudhu info hishebe dekhay (official image er onek CVE ei image maintainer er fix er opor depend kore).

## 8. Backup & restore (S3)

### 8.1 Manual backup test

```bash
./scripts/backup.sh
aws s3 ls s3://<BUCKET>/mongodb/expense_tracker/
```

### 8.2 Daily auto backup (cron)

```bash
crontab -e
```

```cron
# Prottek din 20:00 UTC (= Bangladesh time 02:00 AM)
0 20 * * * /home/ubuntu/expense-tracker/scripts/backup.sh >> /home/ubuntu/expense-tracker/backup.log 2>&1
```

Log dekhte: `tail -f ~/expense-tracker/backup.log`

### 8.3 Restore

```bash
./scripts/restore.sh latest
# ba specific file:
./scripts/restore.sh mongodb/expense_tracker/2026-10-14T20-00-01Z.archive.gz
```

Prothome ekbar restore test kore nio (e.g. `Seed` diye data banao → backup → ekta expense delete koro → restore → data fire ashche kina dekho). Backup tokhoni valid jokhon restore kore dekha hoyeche.

## 9. Security checklist

Already kora ache:

- [x] Non-root container (backend, nginx)
- [x] Multi-stage build, chhoto final image, sudhu runtime file
- [x] `read_only` filesystem, `cap_drop: ALL`, `no-new-privileges`
- [x] Mongo authentication + least-privilege app user
- [x] Mongo/API host e expose kora nai, DB network `internal`
- [x] Secrets `.env` e (`chmod 600`, `.gitignore` e ache), git e jabe na
- [x] S3: private, encrypted, versioned, lifecycle, IAM role (no access keys)
- [x] IMDSv2 only, SSH sudhu My IP theke
- [x] Container log rotation, memory/pids limit
- [x] Docker Scout scan deploy er age

Porer step e korte paro:

- [ ] HTTPS: domain kine DNS point koro, tarpor Caddy ba nginx + certbot (port 443 SG te open korte hobe)
- [ ] `sudo apt-get install -y unattended-upgrades` (auto OS security patch)
- [ ] CloudWatch alarm (CPU, disk, status check) ar billing alert
- [ ] Docker Scout step ta GitHub Actions CI te add kore PR e scan chalano
- [ ] Rate limiting / `helmet` middleware backend e (code change lagbe)

## 10. Troubleshooting

| Problem | Karon / Fix |
|---|---|
| `permission denied ... docker.sock` | Logout/login koro (docker group apply hoy ni) |
| `variable is not set` error | `.env` e oi variable ta fill koro |
| Backend restart loop, `Authentication failed` | Mongo volume age create hoyechilo onno password diye. Init script sudhu **prothom bar** chole. Test environment hole: `docker compose down -v` (**data muche jabe**), tarpor abar `up -d` |
| Browser e open hoy na | Security Group e port 80 open ache kina dekho; `HTTP_PORT=80` kina dekho |
| `502 Bad Gateway` | `docker compose logs backend` dekho; backend healthy na hole nginx proxy korte pare na |
| `docker scout` command nai | Section 4.3 abar koro, `docker login` korte bhulo na |
| `aws s3 cp` AccessDenied | `aws sts get-caller-identity` e role ta dekhay kina; bucket naam `.env` e thik ache kina; IAM policy te bucket naam thik kina |
| Build e killed / OOM | `t3.small` use koro ba swap add koro (4.4) |
| Subnet conflict (`Pool overlaps`) | `docker-compose.yml` e subnet `172.28.x.x` onno range e change koro |

## 11. Update / redeploy

```bash
cd ~/expense-tracker
./scripts/deploy.sh
```

Data (Mongo volume) ei process e safe thake. **Kokhono `docker compose down -v` chalaio na** jodi na data muchte chao.

## 12. Cleanup (cost bachate)

EC2 terminate, Elastic IP release (na korle charge hoy), S3 bucket empty kore delete, IAM role/instance-profile delete.
