#!/usr/bin/env bash
# install_friendgpt.sh — deploys ONE customised GPT chatbot instance
set -euo pipefail

### 0. Require root
[[ $EUID -ne 0 ]] && { echo "Run with sudo/root." >&2; exit 1; }

### 1. Gather inputs

read -rp "➡  Bot instance name (e.g. eligpt): "            INSTANCE
read -rp "➡  Domain for this bot (e.g. eli.example.com): " DOMAIN
read -rp "➡  Linux user to run the service (create if new): " APPUSER
read -rsp "➡  OpenAI API key: " OPENAI_API_KEY; echo
read -rp "➡  Password visitors must enter: "                BOT_PASSWORD
echo "➡  Paste your SYSTEM PROMPT (single line; use \\n for breaks):"
read -r SYSTEM_PROMPT

# NEW: Prompt or generate a Flask secret key
read -rp "➡  Flask Secret Key (leave empty to generate): " FLASK_SECRET_KEY
if [[ -z "$FLASK_SECRET_KEY" ]]; then
  # We’ll generate a 32‐char hex key using openssl if none given
  FLASK_SECRET_KEY=$(openssl rand -hex 16)
  echo "   (No key provided, generated one automatically.)"
fi

# Decide GUNICORN PORT
read -rp "➡  Auto‑assign HTTP port? [Y/n]: " AUTO_PORT
if [[ "${AUTO_PORT,,}" == "n" ]]; then
  read -rp "➡  Port for Gunicorn (e.g. 5050): " PORT
else
  while :; do   # pick free port 5000‑5999 at random
    C=$((5000 + RANDOM % 1000))
    ss -ltn | awk '{print $4}' | grep -q ":${C}$" || { PORT=$C; break; }
  done
fi

# Optional TLS
read -rp "➡  Issue HTTPS cert with Let's Encrypt now? [Y/n]: " WANT_TLS
[[ "${WANT_TLS,,}" != "n" ]] && read -rp "➡  Email for TLS notices: " CERTMAIL

### 2. Variables
PROJECT_DIR="/home/${APPUSER}/${INSTANCE}"
SERVICE_FILE="/etc/systemd/system/${INSTANCE}.service"
NGINX_FILE="/etc/nginx/sites-available/${INSTANCE}"
ENV_FILE="${PROJECT_DIR}/.env"
PY_BIN=$(command -v python3)  # absolute path to python3

### 3. Ensure user exists
id -u "$APPUSER" &>/dev/null || adduser --disabled-password --gecos "" "$APPUSER"

### 4. Install system packages
apt update && apt install -y python3 python3-venv python3-pip \
                             nginx git ufw certbot python3-certbot-nginx openssl

### 5. Firewall
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

### 6. Project skeleton
mkdir -p "${PROJECT_DIR}"/{templates,static}
chown -R "${APPUSER}:${APPUSER}" "${PROJECT_DIR}"

cat > "${PROJECT_DIR}/requirements.txt" <<'REQ'
flask
gunicorn
openai>=1.0.0
python-dotenv
REQ

cat > "$ENV_FILE" <<ENV
OPENAI_API_KEY="${OPENAI_API_KEY}"
BOT_PASSWORD="${BOT_PASSWORD}"
SYSTEM_PROMPT="${SYSTEM_PROMPT}"
FLASK_SECRET_KEY="${FLASK_SECRET_KEY}"
ENV
chmod 600 "$ENV_FILE"
chown "${APPUSER}:${APPUSER}" "$ENV_FILE"

### 7. app.py
cat > "${PROJECT_DIR}/app.py" <<'PY'
import os
import secrets
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from dotenv import load_dotenv
from openai import OpenAI

load_dotenv()

app = Flask(__name__)

# We either use the FLASK_SECRET_KEY from .env or generate a fallback
app.secret_key = os.getenv("FLASK_SECRET_KEY") or secrets.token_hex(16)

client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
PASSWORD = os.getenv("BOT_PASSWORD")
SYSTEM_PROMPT = os.getenv("SYSTEM_PROMPT", "You are a helpful assistant.")

@app.route("/")
def index():
    if session.get("authed") is not True:
        return redirect(url_for("login"))
    return render_template("index.html")

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if request.form.get("password") == PASSWORD:
            session["authed"] = True
            return redirect(url_for("index"))
        return "Wrong password", 403
    return render_template("login.html")

@app.route("/api/chat", methods=["POST"])
def chat():
    q = request.json.get("message", "").strip()
    if not q:
        return jsonify({"error": "Empty message"}), 400
    resp = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": q}
        ],
        temperature=0.85,
        max_tokens=512
    )
    return jsonify({"reply": resp.choices[0].message.content.strip()})
PY
chown "${APPUSER}:${APPUSER}" "${PROJECT_DIR}/app.py"

### 8. Templates & static
cat > "${PROJECT_DIR}/templates/index.html" <<'HTML'
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>FriendGPT Chat</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body>
  <h1>FriendGPT</h1>
  <div id="chat-box"></div>
  <form id="chat-form">
    <input id="user-input" placeholder="Say something…" autocomplete="off" required>
    <button type="submit">Send</button>
  </form>
  <script src="{{ url_for('static', filename='script.js') }}"></script>
</body>
</html>
HTML

cat > "${PROJECT_DIR}/templates/login.html" <<'HTML'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Login</title></head>
<body>
  <h2>Enter Password to Chat</h2>
  <form method="POST">
    <input type="password" name="password" required>
    <button>Access</button>
  </form>
</body>
</html>
HTML

cat > "${PROJECT_DIR}/static/style.css" <<'CSS'
body{font-family:Arial,sans-serif;max-width:600px;margin:2rem auto;}
#chat-box{border:1px solid #ddd;padding:1rem;height:400px;overflow-y:auto;}
.user{font-weight:bold;margin:.5rem 0;}
.bot{color:#333;margin:.5rem 0 1rem;}
form{display:flex;gap:.5rem;}
input{flex:1;padding:.5rem;}button{padding:.5rem 1rem;}
CSS

cat > "${PROJECT_DIR}/static/script.js" <<'JS'
const box = document.getElementById("chat-box");
const form = document.getElementById("chat-form");
const inp = document.getElementById("user-input");

const add = (c, t) => {
  const d = document.createElement("div");
  d.className = c;
  d.textContent = t;
  box.appendChild(d);
  box.scrollTop = box.scrollHeight;
};

form.addEventListener("submit", async e => {
  e.preventDefault();
  const m = inp.value.trim();
  if(!m) return;
  add("user", m);
  inp.value = "";

  const r = await fetch("/api/chat", {
    method:"POST",
    headers:{"Content-Type":"application/json"},
    body: JSON.stringify({message: m})
  });
  const j = await r.json();
  add("bot", j.reply || j.error || "Error");
});
JS

chown -R "${APPUSER}:${APPUSER}" "${PROJECT_DIR}/templates" "${PROJECT_DIR}/static"

### 9. Virtual Env
sudo -u "$APPUSER" bash -c "
  cd '$PROJECT_DIR'
  $PY_BIN -m venv venv
  source venv/bin/activate
  pip install -q -r requirements.txt
"

### 10. systemd service
cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=${INSTANCE} Chatbot
After=network.target

[Service]
User=${APPUSER}
WorkingDirectory=${PROJECT_DIR}
Environment=PATH=${PROJECT_DIR}/venv/bin
ExecStart=${PROJECT_DIR}/venv/bin/gunicorn -w 3 -b 127.0.0.1:${PORT} app:app
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now "$(basename "$SERVICE_FILE")"

### 11. Nginx vhost
cat > "$NGINX_FILE" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:${PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
NGINX

ln -sf "$NGINX_FILE" /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

### 12. HTTPS
if [[ "${WANT_TLS,,}" != "n" ]]; then
  certbot --nginx -d "$DOMAIN" -m "$CERTMAIL" --agree-tos --redirect --non-interactive
fi

### Done
echo -e "\n✅  '${INSTANCE}' deployed at http${WANT_TLS:+s}://${DOMAIN}"
echo    "   • Linux user: ${APPUSER}"
echo    "   • Gunicorn port: ${PORT}"
echo    "   • Password gate enforced ✔"
echo    "   • FLASK_SECRET_KEY stored in .env"
