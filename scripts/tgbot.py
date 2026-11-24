#!/usr/bin/env python3
# 321r Telegram bot v4 — ВСЁ генерируется из кластера (дизайн docs/monitoring.md).
# Никаких ручных конфигов! Источники (авто):
#   - ноды: cluster.yml; базы: /etc/db/apps.d + /var/lib/dbdata; контейнеры/сервисы: docker;
#   - внешние точки: ресурсы Pangolin (БД) + домены сертификатов certbot;
#   - карточки приложений: ГЕНЕРИРУЮТСЯ (БД из apps.d + группы контейнеров по именам).
# Обновление данных: снимок раз в сутки (авто) ИЛИ кнопка «🔄 Обновить» на любом экране.
# Только stdlib (~20-30 МБ). Доступ — только TG_CHAT_ID. Секреты — /etc/db/secrets/.
import json, os, re, shlex, subprocess, sys, time, urllib.parse, urllib.request

ENV = "/etc/db/secrets/telegram.env"
SNAP = "/var/lib/tgbot/snapshot.json"
SSH = "ssh -n -p 2222 -o BatchMode=yes -o ConnectTimeout=5"


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


env = load_env(ENV)
TOKEN = env["TG_BOT_TOKEN"]
ALLOWED = {s.strip() for s in env.get("TG_CHAT_ID", "").split(",") if s.strip()}
API = "https://api.telegram.org/bot" + TOKEN
NODE = (subprocess.run("awk -v s=$(hostname) '$3==s{print $1}' /etc/db/nodes.map",
                       shell=True, capture_output=True, text=True).stdout.strip()
        or subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip().split(".")[0])


def log(msg):
    print(msg, flush=True)


def call(method, timeout=60, **params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(API + "/" + method, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def sh(cmd, timeout=30):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception as e:
        return "(ошибка: %s)" % e


def cluster_nodes():
    nodes = []
    try:
        with open("/etc/db/cluster.yml") as f:
            for line in f:
                m = re.search(r"name:\s*([a-z0-9_-]+).*?ip:\s*([0-9.]+)", line)
                if m:
                    nodes.append((m.group(1), m.group(2)))
    except FileNotFoundError:
        pass
    return nodes


def node_ip(name):
    return dict(cluster_nodes()).get(name, "")


def btn(text, data):
    return {"text": text, "callback_data": data}


def grid(rows):
    return [[btn(t, d) for t, d in row] for row in rows]


BACK = ("◀ В меню", "m:main")
PEND = "/var/lib/tgbot/warp-pending.json"


def pend_set(node, chat_id):
    os.makedirs(os.path.dirname(PEND), exist_ok=True)
    with open(PEND, "w", encoding="utf-8") as f:
        json.dump({"node": node, "chat": str(chat_id), "ts": int(time.time())}, f)


def pend_get():
    try:
        return json.load(open(PEND, encoding="utf-8"))
    except Exception:
        return {}


# ================= СНИМОК КЛАСТЕРА (сбор раз в сутки или по кнопке) =================

def collect():
    """Собрать всё состояние кластера одним махом → snapshot.json."""
    snap = {"time": time.strftime("%Y-%m-%d %H:%M"), "nodes": {}, "swarm": "", "puburls": ""}
    for name, ip in cluster_nodes():
        one = {}
        for key, cmd in [
            ("status", "/usr/local/bin/tg-info.sh status"),
            ("db", "/usr/local/bin/tg-info.sh db"),
            ("disk", "/usr/local/bin/tg-info.sh disk"),
            ("backup", "/usr/local/bin/tg-info.sh backup"),
            ("certs", "/usr/local/bin/tg-info.sh certs"),
            ("local", "/usr/local/bin/tg-info.sh services"),
            ("warp", "/usr/local/bin/warp-321r.sh stats 2>/dev/null || true"),
        ]:
            one[key] = sh("%s root@%s '%s'" % (SSH, ip, cmd), timeout=45)
        one["containers"] = sh("%s root@%s 'docker ps -a --format \"{{.Names}}|{{.Status}}\"'" % (SSH, ip), timeout=20).splitlines()
        one["apps"] = sh("%s root@%s 'for f in /etc/db/apps.d/*.yaml; do sed -n \"s/^name: */name=/p; s/^engine: */engine=/p; s/^placement: */placement=/p; s/^port: */port=/p\" $f | tr \"\\n\" \"|\"; echo; done'" % (SSH, ip), timeout=20).splitlines()
        one["units"] = sh("%s root@%s 'systemctl list-units --type=service --state=running --no-pager --plain --no-legend | awk \"{print \\$1}\" | grep -E \"mtproto|pangolin|periphery|db-guard|tgbot\"'" % (SSH, ip), timeout=20).splitlines()
        snap["nodes"][name] = one
    snap["swarm"] = sh("docker service ls --format '{{.Name}}|{{.Replicas}}|{{.Image}}' 2>/dev/null", timeout=20)
    # внешние точки ГЕНЕРИРУЮТСЯ: ресурсы Pangolin (из его БД) + домены сертификатов
    urls = sh(""". /etc/db/secrets/pangolin.env 2>/dev/null; docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" pg-pangolin psql -h 10.66.0.99 -U postgres -d pangolin -tAc "SELECT 'https://'||"'"'"fullDomain"'"'"' FROM resources WHERE enabled = true" 2>/dev/null""", timeout=25)
    certs = sh("certbot certificates 2>/dev/null | grep -oE '[a-z0-9.-]+\\.321r\\.ru' | sort -u", timeout=20)
    mask = ["https://%s/" % d for d in certs.splitlines() if d.startswith(("vpn-", "tg."))]
    snap["puburls"] = "\n".join(sorted(set([u for u in urls.splitlines() if u.startswith("http")] + mask)))
    os.makedirs(os.path.dirname(SNAP), exist_ok=True)
    with open(SNAP, "w", encoding="utf-8") as f:
        json.dump(snap, f, ensure_ascii=False)
    log("tgbot: снимок собран (%s)" % snap["time"])
    return snap


def snap(fresh=False):
    s = None
    if not fresh:
        try:
            s = json.load(open(SNAP, encoding="utf-8"))
            t = os.path.getmtime(SNAP)
            if time.time() - t > 86400:   # снимок живёт сутки
                s = None
        except Exception:
            s = None
    return s or collect()


# ================= АВТО-ГЕНЕРАЦИЯ КАРТОЧЕК ПРИЛОЖЕНИЙ =================

def auto_cards(s):
    """Карточки генерируются сами: БД-приложения из apps.d + группы контейнеров по корням имён.
    БД-карточки и группы контейнеров разделены ДАЖЕ при совпадении имён (панель ≠ ноды)."""
    cards = {}
    # 1) БД-приложения из apps.d (имя/engine/placement/порт)
    for name, one in s["nodes"].items():
        for ln in one.get("apps", []):
            kv = dict((p.split("=", 1)[0], p.split("=", 1)[1].split("#")[0].strip()) for p in ln.strip("|").split("|") if "=" in p)
            app = kv.get("name")
            if not app:
                continue
            cards.setdefault(app, {"id": app, "title": "🗄 БД %s (%s)" % (app, kv.get("engine", "?")),
                                    "desc": "placement %s · порт VIP %s · управление инстансами ниже" % (kv.get("placement", "?"), kv.get("port", "?")),
                                    "db": app, "ct": [], "units": [], "urls": []})
    # 2) БД-контейнеры (pg-*/mongod-*) — в карточку своего приложения
    for name, one in s["nodes"].items():
        for line in one.get("containers", []):
            ct = line.split("|")[0]
            m = re.match(r"(pg|mongod)-(.+)", ct)
            if m and m.group(2) in cards:
                c = cards[m.group(2)]
                if ct not in [x[0] for x in c["ct"]]:
                    c["ct"].append((ct, ct))
    # 3) группы остальных контейнеров по корню имени — отдельные карточки «g:»
    def root(n):
        n = n.split(".")[0]
        return re.split(r"[-_]", n)[0] if re.search(r"[-_]", n) else n
    for name, one in s["nodes"].items():
        for line in one.get("containers", []):
            ct = line.split("|")[0]
            if ct.startswith(("pg-", "mongod-")):
                continue
            r = root(ct)
            gid = "g:" + r
            c = cards.setdefault(gid, {"id": gid, "title": "🧩 " + r, "desc": "авто-группа (контейнеры/юниты)", "db": None, "ct": [], "units": [], "urls": []})
            if ct not in [x[0] for x in c["ct"]]:
                c["ct"].append((ct, ct))
    # 4) systemd-юниты — в группу по корню имени
    for name, one in s["nodes"].items():
        for u in one.get("units", []):
            r = root(u)
            gid = "g:" + r
            c = cards.setdefault(gid, {"id": gid, "title": "🧩 " + r, "desc": "авто-группа (контейнеры/юниты)", "db": None, "ct": [], "units": [], "urls": []})
            if u not in [x[0] for x in c["units"]]:
                c["units"].append((u, u))
    return cards


# ================= ЭКРАНЫ (всё из снимка) =================

def scr_main():
    return ("321r · панель кластера\nВсё генерируется из кластера; снимок обновляется раз в сутки или по кнопке.",
            grid([[("📊 Статус", "m:status"), ("🟢 Внешние точки", "m:services")],
                  [("🧩 Приложения", "m:apps"), ("📦 Контейнеры", "m:ctop")],
                  [("💾 Бэкапы", "m:backup"), ("🗄 Базы данных", "m:db")],
                  [("🖥 Серверы", "m:srv"), ("📜 Логи", "m:logs")],
                  [("🛡 WARP/mtproto", "m:warp"), ("⚙ Действия", "m:act")],
                  [("ℹ Помощь", "m:help")]]))


def stamp(s):
    return "⏱ снимок %s" % s.get("time", "?")


def scr_status(_=""):
    s = snap()
    lines = ["📊 Статус кластера · " + stamp(s), ""]
    for name, one in s["nodes"].items():
        lines.append("【%s】 %s" % (name, " · ".join(x.strip() for x in one.get("status", "").splitlines() if x.strip())))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "r:m:status")], [BACK]]))


def scr_services(_=""):
    s = snap()
    lines = ["🟢 Внешние точки (генерируются из ресурсов Pangolin и сертификатов) · " + stamp(s), ""]
    for url in [u for u in s.get("puburls", "").splitlines() if u]:
        code = sh("curl -sk -o /dev/null -w %%{http_code} --max-time 8 %s" % shlex.quote(url), timeout=12)
        lines.append("%s %s — %s" % ("✅" if code == "200" else "⚠", url.replace("https://", ""), code or "нет ответа"))
    lines.append("")
    for name, one in s["nodes"].items():
        lines.append("【%s】 %s" % (name, " · ".join(x.strip() for x in one.get("local", "").splitlines() if x.strip())))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "r:m:services")], [BACK]]))


def warp_state(one):
    w = one.get("warp", "") or ""
    return "up" if w.startswith("warp: up") else ("down" if w.startswith("warp: down") else "?")


def warp_icon(st):
    return {"up": "🟢", "down": "⚪"}.get(st, "❔")


def scr_warp(_=""):
    s = snap()
    lines = ["🛡 WARP/mtproto · обход блокировки Telegram (РФ) через Cloudflare WARP", stamp(s), ""]
    for name, one in s["nodes"].items():
        body = " · ".join(x.strip() for x in (one.get("warp") or "").splitlines() if x.strip()) or "нет данных"
        lines.append("【%s】 %s %s" % (name, warp_icon(warp_state(one)), body))
    rows = []
    ns = [n for n, _ in cluster_nodes()]
    for i in range(0, len(ns), 2):
        rows.append([("%s %s" % (n, warp_icon(warp_state(s["nodes"].get(n, {})))), "ask:warptoggle:" + n)
                     for n in ns[i:i + 2]])
    rows.append([("✅ Включить на всех", "ask:warpall:on"), ("⛔ Выключить на всех", "ask:warpall:off")])
    rows.append([("📄 Заменить WARP-конфиг", "m:warp-cfg")])
    rows.append([("🔄 Обновить", "r:m:warp")])
    rows.append([BACK])
    return ("\n".join(lines)[:3900], grid(rows))


def scr_warp_cfg(_=""):
    ns = cluster_nodes()
    rows = [[(n, "p:warp-cfg:" + n) for n, _ in ns[i:i + 2]] for i in range(0, len(ns), 2)]
    rows.append([("◀ Назад", "m:warp"), BACK])
    return ("📄 Замена WARP-конфига — конфиг СВОЙ на каждую ноду.\n"
            "Выберите ноду и отправьте файл .conf сюда: бот положит его на ноду и применит. "
            "Если туннель не поднимется — автоматически откатит прежний.", grid(rows))


def scr_warp_pend(arg):
    return ("📄 Жду файл .conf для ноды %s — отправьте его сообщением." % arg,
            grid([[("◀ Назад", "m:warp-cfg")]]))


def scr_backup(_=""):
    s = snap()
    lines = ["💾 Бэкапы (правило 3-2-1) · " + stamp(s), ""]
    for name, one in s["nodes"].items():
        lines.append("【%s】 %s" % (name, " · ".join(x.strip() for x in one.get("backup", "").splitlines() if x.strip())))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "r:m:backup")],
                  [("🚀 Прогнать сейчас", "ask:backup"), ("🧪 Верификация", "ask:verify")],
                  [("📦 Выгрузить на диск", "ask:export")], [BACK]]))


def scr_db(_=""):
    s = snap()
    lines = ["🗄 Базы данных (авто-обнаружение по /var/lib/dbdata) · " + stamp(s), ""]
    for name, one in s["nodes"].items():
        lines.append("【%s】 %s" % (name, " · ".join(x.strip() for x in one.get("db", "").splitlines() if x.strip())))
    return ("\n".join(lines)[:3900],
            grid([[("🔄 Обновить", "r:m:db")], [BACK]]))


def scr_ctop(_=""):
    s = snap()
    lines = ["📦 Контейнеры и сервисы (живой инвентарь) · " + stamp(s), ""]
    for name, one in s["nodes"].items():
        cts = [c.split("|")[0] for c in one.get("containers", [])]
        lines.append("【%s】 %d шт: %s" % (name, len(cts), ", ".join(cts[:8]) + ("…" if len(cts) > 8 else "")))
    lines.append("")
    lines.append("Swarm-сервисы:")
    for ln in s.get("swarm", "").splitlines():
        p = ln.split("|")
        if len(p) == 3:
            lines.append("  %s — реплик %s — %s" % tuple(p))
    rows = [[(n, "m:ct:" + n) for n, _ in cluster_nodes()]]
    rows.append([("🔄 Обновить", "r:m:ctop")])
    rows.append([BACK])
    return ("\n".join(lines)[:3900], grid(rows))


def scr_ct(arg):
    s = snap()
    one = s["nodes"].get(arg, {})
    rows = []
    cts = [c.split("|")[0] for c in one.get("containers", [])]
    for i in range(0, min(len(cts), 14), 2):
        rows.append([(cts[i], "m:ci:" + arg + ":" + cts[i])] +
                    ([(cts[i + 1], "m:ci:" + arg + ":" + cts[i + 1])] if i + 1 < len(cts) else []))
    rows.append([("◀ Назад", "m:ctop")])
    return ("📦 Контейнеры на %s (живой список):" % arg, grid(rows))


def scr_ci(arg):
    node, ct = arg.split(":", 1)
    st = sh("%s root@%s 'docker inspect -f {{.State.Status}} %s 2>/dev/null'" % (SSH, node_ip(node), shlex.quote(ct)), timeout=10)
    return ("📦 «%s» на %s — %s" % (ct, node, st or "нет данных"),
            grid([[("📜 Логи", "m:lt:" + arg)],
                  [("🔄 Перезапустить", "ask:restart:" + arg)],
                  [("◀ Назад", "m:ct:" + node)]]))


def scr_apps(_=""):
    s = snap()
    cards = auto_cards(s)
    ids = sorted(cards)
    rows = [[(cards[ids[i + j]]["title"].split("(")[0][:18], "m:app:" + ids[i + j]) for j in (0, 1) if i + j < len(ids)] for i in range(0, len(ids), 2)]
    rows.append([("🔄 Обновить", "r:m:apps")])
    rows.append([BACK])
    return ("🧩 Приложения (генерируются автоматически: %d групп) · %s" % (len(ids), stamp(s)), grid(rows))


def app_components(app, node, ip, cards):
    a = cards.get(app, {})
    parts = [c for c, _ in a.get("ct", [])]
    units = [u for u, _ in a.get("units", [])]
    cmd = ""
    if parts:
        cmd += "for c in %s; do printf '%%s=%%s ' $c $(docker inspect -f '{{.State.Status}}' $c 2>/dev/null || echo нет); done; " % " ".join(shlex.quote(p) for p in parts)
    if units:
        cmd += "for u in %s; do printf '%%s=%%s ' $u $(systemctl is-active $u 2>/dev/null || echo -); done" % " ".join(shlex.quote(u) for u in units)
    return sh("%s root@%s %s" % (SSH, ip, shlex.quote(cmd.strip())), timeout=15) if cmd.strip() else ""


def scr_app(arg):
    s = snap()
    cards = auto_cards(s)
    a = cards.get(arg)
    if not a:
        return scr_apps()
    lines = [a["title"], a["desc"], ""]
    if a.get("urls"):
        for url in a["urls"]:
            code = sh("curl -sk -o /dev/null -w %%{http_code} --max-time 8 %s" % shlex.quote(url), timeout=12)
            lines.append("%s %s — %s" % ("✅" if code == "200" else "⚠", url.replace("https://", ""), code or "нет"))
        lines.append("")
    lines.append("Ноды и компоненты:")
    for name, ip in cluster_nodes():
        comp = app_components(arg, name, ip, cards) or ""
        db = ""
        if a.get("db"):
            for ln in s["nodes"].get(name, {}).get("db", "").splitlines():
                if re.match(r"(pg|mongo) %s:" % re.escape(a["db"]), ln.strip()):
                    db = ln.strip()
        parts_line = " · ".join(x for x in (db, comp) if x)
        lines.append("【%s】 %s" % (name, parts_line or "-"))
    rows = [[("🔄 Обновить", "r:m:app:" + arg)]]
    if a.get("db"):
        rows.append([("🧩 Инстансы БД", "m:inst:" + arg)])
    rows.append([("📜 Логи", "m:appc:" + arg), ("⚙ Перезапуск", "m:appr:" + arg)])
    rows.append([("🧩 Приложения", "m:apps"), BACK])
    return ("\n".join(lines)[:3900], grid(rows))


def scr_appc(arg):
    s = snap()
    cards = auto_cards(s)
    a = cards.get(arg, {})
    picks = []
    for ct, lbl in a.get("ct", []):
        for name, ip in cluster_nodes():
            if sh("%s root@%s 'docker inspect -f {{.State.Status}} %s 2>/dev/null'" % (SSH, ip, shlex.quote(ct)), timeout=8):
                picks.append(("%s @%s" % (ct, name), "m:lt:" + name + ":" + ct))
    for u, lbl in a.get("units", []):
        for name, ip in cluster_nodes():
            st = sh("%s root@%s 'systemctl is-active %s 2>/dev/null'" % (SSH, ip, shlex.quote(u)), timeout=8)
            if st and st != "inactive":
                picks.append(("%s @%s" % (u, name), "m:lt:" + name + ":" + u))
    rows = [[picks[i + j] for j in (0, 1) if i + j < len(picks)] for i in range(0, min(len(picks), 12), 2)]
    rows.append([("◀ Назад", "m:app:" + arg)])
    return ("📜 Логи — выберите компонент:", grid(rows))


def scr_appr(arg):
    s = snap()
    cards = auto_cards(s)
    a = cards.get(arg, {})
    picks = []
    for ct, lbl in a.get("ct", []):
        for name, ip in cluster_nodes():
            if sh("%s root@%s 'docker inspect -f {{.State.Status}} %s 2>/dev/null'" % (SSH, ip, shlex.quote(ct)), timeout=8):
                picks.append(("%s @%s" % (ct, name), "ask:restart:" + name + ":" + ct))
    rows = [[picks[i + j] for j in (0, 1) if i + j < len(picks)] for i in range(0, min(len(picks), 12), 2)]
    rows.append([("◀ Назад", "m:app:" + arg)])
    return ("⚙ Перезапуск — выберите компонент (будет подтверждение):", grid(rows))


def scr_srv(_=""):
    rows = [[(n, "m:srv:" + n) for n, _ in cluster_nodes()]]
    rows.append([("🔄 Обновить", "r:m:srv")])
    rows.append([BACK])
    return ("🖥 Серверы — выберите ноду:", grid(rows))


def scr_srv_node(arg):
    return ("🖥 Нода %s:" % arg,
            grid([[("📊 Статус", "m:sn:" + arg + ":status"), ("💿 Диски", "m:sn:" + arg + ":disk")],
                  [("🗄 Базы", "m:sn:" + arg + ":db"), ("📜 Логи", "m:sn:" + arg + ":logs")],
                  [("📦 Контейнеры", "m:ct:" + arg)],
                  [("◀ Серверы", "m:srv"), BACK]]))


def scr_srv_node_info(arg):
    name, sub = arg.split(":", 1)
    s = snap()
    key = "local" if sub == "services" else sub
    body = s["nodes"].get(name, {}).get(key, "")
    return ("🖥 %s · %s · %s\n%s" % (name, sub, stamp(s), (body or "нет данных"))[:3900],
            grid([[("🔄 Обновить", "r:m:sn:" + arg)], [("◀ Назад", "m:srv:" + name)]]))


def scr_logs(_=""):
    rows = [[(n, "m:lg:" + n) for n, _ in cluster_nodes()]]
    rows.append([BACK])
    return ("📜 Логи — выберите ноду:", grid(rows))


def scr_logs_node(arg):
    s = snap()
    one = s["nodes"].get(arg, {})
    picks = [("db-guard", "m:lt:" + arg + ":db-guard"), ("backup-321r", "m:lt:" + arg + ":backup321r"),
             ("система (за час)", "m:lt:" + arg + ":syslog")]
    cts = [c.split("|")[0] for c in one.get("containers", [])][:10]
    rows = [[picks[i + j] for j in (0, 1) if i + j < len(picks)] for i in range(0, len(picks), 2)]
    for i in range(0, len(cts), 2):
        rows.append([(cts[i], "m:lt:" + arg + ":" + cts[i])] +
                    ([(cts[i + 1], "m:lt:" + arg + ":" + cts[i + 1])] if i + 1 < len(cts) else []))
    rows.append([("◀ Назад", "m:logs"), BACK])
    return ("📜 Логи на %s — что показать?" % arg, grid(rows))


def scr_lt(arg):
    name, what = arg.split(":", 1)
    ip = node_ip(name)
    if what == "syslog":
        body = sh("%s root@%s 'journalctl --since -1h --no-pager | tail -20'" % (SSH, ip), timeout=25)
    elif what == "backup321r":
        body = sh("%s root@%s 'tail -20 /var/log/backup321r.log 2>/dev/null'" % (SSH, ip), timeout=25)
    elif what == "db-guard":
        body = sh("%s root@%s 'journalctl -t db-guard --since -2h --no-pager | tail -20'" % (SSH, ip), timeout=25)
    else:
        body = sh("%s root@%s 'docker logs --tail 20 %s 2>&1'" % (SSH, ip, shlex.quote(what)), timeout=25)
    return ("📜 %s · %s\n%s" % (name, what, (body or "пусто"))[:3900],
            grid([[("🔄 Обновить", "m:lt:" + arg)], [("◀ Назад", "m:lg:" + name)]]))


def scr_act(_=""):
    return ("⚙ Действия (опасные — с подтверждением):",
            grid([[("🚀 Бэкап сейчас", "ask:backup")],
                  [("🧪 Верификация восстановления", "ask:verify")],
                  [("📦 Выгрузка на физ. диск", "ask:export")],
                  [("⚠ АВАРИЙНЫЙ РЕЖИМ", "ask:survival")], [BACK]]))


def scr_ask(arg):
    titles = {"backup": "Прогнать бэкап на всех нодах?",
              "verify": "Запустить верификацию восстановления (несколько минут)?",
              "export": "Выгрузить бэкапы вам в чат для записи на диск?",
              "survival": "⚠ АВАРИЙНЫЙ РЕЖИМ — потеря последних записей и риск split-brain! Поднимать выжившие инстансы принудительно?"}
    t = titles.get(arg, "Выполнить?")
    if arg.startswith("restart:"):
        _, n, c = arg.split(":", 2)
        t = "Перезапустить контейнер «%s» на ноде %s?" % (c, n)
    elif arg.startswith("member-add:"):
        _, app, n = arg.split(":", 2)
        t = "Добавить инстанс БД «%s» на ноду %s? (копия данных через VIP, ~1 мин)" % (app, n)
    elif arg.startswith("member-remove:"):
        _, app, n = arg.split(":", 2)
        t = "Убрать инстанс БД «%s» с ноды %s? (данные останутся на диске)" % (app, n)
    elif arg.startswith("move:"):
        _, app, f, to = arg.split(":", 3)
        t = "Перенести инстанс БД «%s» с %s на %s? (даунтайм ~10–20 с)" % (app, f, to)
    elif arg.startswith("warptoggle:"):
        t = "WARP на ноде %s: переключить (вкл/выкл)?" % arg.split(":", 1)[1]
    elif arg.startswith("warpall:"):
        t = ("Включить WARP на всех нодах?" if arg.endswith("on") else "Выключить WARP на всех нодах?")
    return (t, grid([[("✅ Да, выполнить", "do:" + arg)], [("❌ Отмена", "m:main")]]))


def scr_help(_=""):
    return ("ℹ 321r · панель кластера\n\n"
            "ВСЁ генерируется из кластера автоматически — без ручных настроек:\n"
            "· серверы — cluster.yml · базы — apps.d/dbdata\n"
            "· контейнеры и swarm-сервисы — docker · точки — ресурсы Pangolin + сертификаты\n"
            "· карточки приложений — авто-группы (БД + контейнеры по именам)\n\n"
            "Данные: снимок раз в сутки ИЛИ кнопка 🔄 Обновить на любом экране.\n"
            "Новое на серверах (контейнер/сервис/база/нода) появляется само после обновления.\n"
            "🛡 WARP/mtproto — обход блокировки Telegram в РФ: вкл/выкл, статистика, замена конфига файлом.\n"
            "Алерты приходят сюда сами. Текстовые команды тоже работают.",
            grid([[BACK]]))


def scr_inst(arg):
    s = snap()
    lines = ["🧩 Инстансы БД «%s»" % arg, ""]
    members, placement = [], "?"
    for name, one in s["nodes"].items():
        for ln in one.get("apps", []):
            kv = dict(p.split("=", 1) for p in ln.strip("|").split("|") if "=" in p)
            if kv.get("name") == arg:
                placement = kv.get("placement", placement)
                members = [x.strip() for x in kv.get("placement", "").strip("[]").split(",") if x.strip()]
                break
        if members:
            break
    lines.append("placement: %s" % placement)
    for name, one in s["nodes"].items():
        db = ""
        for ln in one.get("db", "").splitlines():
            if re.match(r"(pg|mongo) %s:" % re.escape(arg), ln.strip()):
                db = ln.strip()
        if name in members:
            lines.append("【%s】 %s" % (name, db or "в группе"))
        else:
            lines.append("【%s】 свободна" % name)
    rows = []
    if len(members) > 1:
        rows.append([("↔ Перенести инстанс", "m:instm:" + arg)])
    rows.append([("➕ Добавить инстанс", "m:instd:" + arg), ("➖ Убрать инстанс", "m:instr:" + arg)])
    rows.append([("🔄 Обновить", "r:m:inst:" + arg), ("◀ Назад", "m:app:" + arg)])
    return ("\n".join(lines)[:3900], grid(rows))


def inst_members(app):
    for name, _ip in cluster_nodes():
        pl = sh("%s root@%s 'sed -n \"s/^placement: *//p\" /etc/db/apps.d/%s.yaml 2>/dev/null'" % (SSH, node_ip(name), shlex.quote(app)), timeout=12)
        if pl:
            return [x.strip() for x in pl.split("#")[0].strip().strip("[]").split(",") if x.strip()]
    return []


def scr_instd(arg):
    members = inst_members(arg)
    free = [n for n, _ in cluster_nodes() if n not in members]
    rows = [[(f, "ask:member-add:" + arg + ":" + f) for f in free[i:i + 2]] for i in range(0, len(free), 2)]
    if not rows:
        return ("➕ Добавить инстанс %s: свободных нод нет." % arg, grid([[("◀ Назад", "m:inst:" + arg)]]))
    rows.append([("◀ Назад", "m:inst:" + arg)])
    return ("➕ Добавить инстанс БД «%s» — на какую ноду?" % arg, grid(rows))


def scr_instr(arg):
    members = inst_members(arg)
    rows = [[(h, "ask:member-remove:" + arg + ":" + h) for h in members[i:i + 2]] for i in range(0, len(members), 2)]
    rows.append([("◀ Назад", "m:inst:" + arg)])
    return ("➖ Убрать инстанс БД «%s» — с какой ноды? (первичный нельзя — сначала перенос)" % arg, grid(rows))


def scr_instm(arg):
    app, frm = arg.split(":", 1)
    members = inst_members(app)
    free = [n for n, _ in cluster_nodes() if n not in members and n != frm]
    rows = [[(f, "ask:move:" + app + ":" + frm + ":" + f) for f in free[i:i + 2]] for i in range(0, len(free), 2)]
    rows.append([("◀ Назад", "m:inst:" + app)])
    return ("↔ Перенести инстанс «%s» с %s — на какую ноду?" % (app, frm), grid(rows))


def render(data):
    if data.startswith("m:app:"):
        return scr_app(data[6:])
    if data.startswith("m:appc:"):
        return scr_appc(data[7:])
    if data.startswith("m:appr:"):
        return scr_appr(data[7:])
    if data.startswith("m:instm:"):
        return scr_instm(data[8:])
    if data.startswith("m:instd:"):
        return scr_instd(data[8:])
    if data.startswith("m:instr:"):
        return scr_instr(data[8:])
    if data.startswith("m:inst:"):
        return scr_inst(data[7:])
    if data.startswith("m:sn:"):
        return scr_srv_node_info(data[5:])
    if data.startswith("m:srv:"):
        return scr_srv_node(data[6:])
    if data.startswith("m:ct:"):
        return scr_ct(data[5:])
    if data.startswith("m:ci:"):
        return scr_ci(data[5:])
    if data.startswith("m:lg:"):
        return scr_logs_node(data[5:])
    if data.startswith("m:lt:"):
        return scr_lt(data[5:])
    if data.startswith("ask:"):
        return scr_ask(data[4:])
    table = {"m:main": scr_main, "m:status": scr_status, "m:services": scr_services,
             "m:backup": scr_backup, "m:db": scr_db, "m:ctop": scr_ctop, "m:apps": scr_apps,
             "m:srv": scr_srv, "m:logs": scr_logs, "m:act": scr_act, "m:help": scr_help,
             "m:warp": scr_warp, "m:warp-cfg": scr_warp_cfg}
    f = table.get(data)
    return f() if f else scr_main()


# ================= ДЕЙСТВИЯ =================

def do_action(chat_id, action, msg_id=None):
    def finish(text, kb=None):
        try:
            call("editMessageText", chat_id=chat_id, message_id=msg_id, text=text[:3900],
                 reply_markup=json.dumps({"inline_keyboard": kb or grid([[("◀ В меню", "m:main")]])}))
        except Exception:
            pass

    if action.startswith("refresh:"):
        scr = action[8:]
        finish("🔄 Снимаю состояние кластера…")
        collect()
        t, k = render(scr)
        finish(t, k)
        return
    if action.startswith("restart:"):
        _, n, c = action.split(":", 2)
        out = sh("%s root@%s 'docker restart %s'" % (SSH, node_ip(n), shlex.quote(c)), timeout=60)
        log("tgbot: restart %s@%s -> %s" % (c, n, out))
        finish("✅ «%s» на %s перезапущен.%s" % (c, n, (" (" + out + ")") if out else ""))
        return
    if action.startswith("member-add:"):
        _, app, n = action.split(":", 2)
        out = sh("/usr/local/bin/app-member.sh add %s %s 2>&1 | tail -7" % (shlex.quote(app), shlex.quote(n)), timeout=1800)
        finish("➕ Инстанс «%s» → %s\n%s" % (app, n, out[:1600]))
        return
    if action.startswith("member-remove:"):
        _, app, n = action.split(":", 2)
        out = sh("/usr/local/bin/app-member.sh remove %s %s 2>&1 | tail -6" % (shlex.quote(app), shlex.quote(n)), timeout=120)
        finish("➖ Инстанс «%s» с %s\n%s" % (app, n, out[:1600]))
        return
    if action.startswith("move:"):
        _, app, f, to = action.split(":", 3)
        out = sh("/usr/local/bin/app-move.sh %s %s %s 2>&1 | tail -9" % (shlex.quote(app), shlex.quote(f), shlex.quote(to)), timeout=1800)
        finish("↔ Перенос «%s»: %s → %s\n%s" % (app, f, to, out[:1600]))
        return
    if action.startswith("warptoggle:"):
        n = action.split(":", 1)[1]
        st = sh("%s root@%s '/usr/local/bin/warp-321r.sh status 2>/dev/null'" % (SSH, node_ip(n)), timeout=15)
        cmd = "down" if st.startswith("warp: up") else "up"
        out = sh("%s root@%s '/usr/local/bin/warp-321r.sh %s 2>&1 | tail -2'" % (SSH, node_ip(n), cmd), timeout=120)
        finish(("⛔ WARP выключен" if cmd == "down" else "✅ WARP включён") + " на %s\n%s" % (n, out[:800]))
        return
    if action.startswith("warpall:"):
        cmd = "up" if action.endswith("on") else "down"
        for n, ip in cluster_nodes():
            sh("%s root@%s '/usr/local/bin/warp-321r.sh %s >/dev/null 2>&1 || true'" % (SSH, ip, cmd), timeout=120)
        collect()
        finish(("✅ WARP включён" if cmd == "up" else "⛔ WARP выключен") + " на всех нодах.")
        return
    if action == "backup":
        for n, ip in cluster_nodes():
            sh("%s root@%s 'nohup /usr/local/bin/backup-321r.sh >/dev/null 2>&1 &'" % (SSH, ip), timeout=10)
        finish("🚀 Бэкап запущен на всех нодах. Итоги придут алертами.")
    elif action == "verify":
        for n, ip in cluster_nodes():
            sh("%s root@%s 'nohup /usr/local/bin/backup-verify.sh >/dev/null 2>&1 &'" % (SSH, ip), timeout=10)
        finish("🧪 Верификация восстановления запущена. Итог придёт алертом.")
    elif action == "export":
        for n, ip in cluster_nodes():
            sh("%s root@%s 'nohup /usr/local/bin/tg-export.sh >/dev/null 2>&1 &'" % (SSH, ip), timeout=10)
        finish("📦 Выгрузка запущена — файлы придут сюда сообщениями.")
    elif action == "survival":
        for n, ip in cluster_nodes():
            sh("%s root@%s /usr/local/bin/survival.sh 2>&1 | tail -2" % (SSH, ip), timeout=90)
            log("tgbot: survival на %s" % n)
        finish("⚠ Аварийный режим разослан. Если первичные были живы — предохранитель ничего не тронул.")
    else:
        finish("Неизвестное действие.")


def handle_callback(cb):
    cid, data = cb.get("id"), cb.get("data", "")
    msg = cb.get("message") or {}
    chat_id, msg_id = str(msg.get("chat", {}).get("id", "")), msg.get("message_id")
    if chat_id not in ALLOWED:
        return
    try:
        call("answerCallbackQuery", callback_query_id=cid)
    except Exception:
        pass
    log("tgbot: кнопка %r" % data)
    try:
        if data.startswith("p:"):
            node = data.split(":", 2)[2]
            pend_set(node, chat_id)
            text, keyboard = scr_warp_pend(node)
            call("editMessageText", chat_id=chat_id, message_id=msg_id, text=text[:3900],
                 reply_markup=json.dumps({"inline_keyboard": keyboard}))
            return
        if data.startswith("do:"):
            do_action(chat_id, data[3:], msg_id)
            return
        if data.startswith("r:"):            # обновить снимок и показать экран
            do_action(chat_id, "refresh:" + data[2:], msg_id)
            return
        text, keyboard = render(data)
        call("editMessageText", chat_id=chat_id, message_id=msg_id, text=text[:3900],
             reply_markup=json.dumps({"inline_keyboard": keyboard}))
    except Exception as e:
        log("tgbot: ошибка экрана %r: %s" % (data, e))


def send_menu(chat_id):
    t, k = scr_main()
    try:
        call("sendMessage", chat_id=chat_id, text=t, reply_markup=json.dumps({"inline_keyboard": k}))
    except Exception as e:
        log("tgbot: ошибка меню: %s" % e)


def handle_text(chat_id, text):
    parts = text.split()
    cmd = parts[0].split("@")[0].lstrip("/") if text else ""
    alias = {"start": "m:main", "menu": "m:main", "help": "m:help", "status": "m:status",
             "services": "m:services", "backup": "m:backup", "db": "m:db", "disk": "m:srv",
             "logs": "m:logs", "apps": "m:apps", "containers": "m:ctop", "warp": "m:warp"}
    if cmd == "ping":
        try:
            call("sendMessage", chat_id=chat_id, text="pong · нода " + NODE)
        except Exception:
            pass
    elif cmd == "restart" and len(parts) > 1:
        t, k = scr_ask("restart:" + NODE + ":" + parts[1])
        try:
            call("sendMessage", chat_id=chat_id, text=t, reply_markup=json.dumps({"inline_keyboard": k}))
        except Exception:
            pass
    elif cmd in alias:
        if alias[cmd] == "m:main":
            send_menu(chat_id)
        else:
            t, k = render(alias[cmd])
            try:
                call("sendMessage", chat_id=chat_id, text=t, reply_markup=json.dumps({"inline_keyboard": k}))
            except Exception:
                pass
    elif cmd:
        try:
            call("sendMessage", chat_id=chat_id, text="Неизвестная команда — меню:",
                 reply_markup=json.dumps({"inline_keyboard": scr_main()[1]}))
        except Exception:
            pass


def handle_document(chat_id, msg):
    """Замена WARP-конфига: бот принимает .conf, кладёт на ноду, применяет с откатом."""
    p = pend_get()
    if not p or p.get("chat") != chat_id or time.time() - p.get("ts", 0) > 3600:
        return
    node, ip = p["node"], node_ip(p["node"])
    doc = msg.get("document") or {}
    fname = doc.get("file_name", "")
    if not fname.endswith(".conf"):
        try:
            call("sendMessage", chat_id=chat_id, text="⚠ Жду .conf (WireGuard/AmneziaWG), а не «%s»." % fname)
        except Exception:
            pass
        return
    try:
        r = call("getFile", file_id=doc["file_id"])
        url = "https://api.telegram.org/file/bot%s/%s" % (TOKEN, r["result"]["file_path"])
        local = "/tmp/warp-%s-%d.conf" % (node, int(time.time()))
        urllib.request.urlretrieve(url, local)
        sh("scp -q -P 2222 -o BatchMode=yes -o ConnectTimeout=8 %s root@%s:/tmp/warp-new.conf"
           % (shlex.quote(local), ip), timeout=40)
        res = sh("%s root@%s '/usr/local/bin/warp-321r.sh set-config /tmp/warp-new.conf 2>&1 | tail -4'"
                 % (SSH, ip), timeout=120)
        os.remove(local)
        call("sendMessage", chat_id=chat_id, text=("✅ WARP-конфиг ноды %s:\n%s" % (node, res))[:3900])
    except Exception as e:
        log("tgbot: warp config: %s" % e)
        try:
            call("sendMessage", chat_id=chat_id, text="⚠ Конфиг не применён: %s" % e)
        except Exception:
            pass
    finally:
        try:
            os.remove(PEND)
        except Exception:
            pass
    collect()


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--screen":
        s = sys.argv[2]
        if not (s.startswith("m:") or s.startswith("ask:") or s.startswith("r:")):
            s = "m:" + s
        t, _ = render(s)
        print(t)
        return
    if len(sys.argv) > 1 and sys.argv[1] == "--collect":
        collect()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "--cards":
        s = snap()
        for cid, c in sorted(auto_cards(s).items()):
            print("%s :: %s :: ct=%s units=%s" % (cid, c["title"], [x[0] for x in c["ct"]], [x[0] for x in c["units"]]))
        return
    offset = 0
    last_snap = 0
    log("tgbot: старт на ноде " + NODE)
    for chat in ALLOWED:
        send_menu(chat)
    while True:
        try:
            if time.time() - last_snap > 86400:    # авто-снимок раз в сутки
                collect()
                last_snap = time.time()
            r = call("getUpdates", timeout=50, offset=offset,
                     allowed_updates=json.dumps(["message", "callback_query"]))
            for u in r.get("result", []):
                offset = u["update_id"] + 1
                if "callback_query" in u:
                    handle_callback(u["callback_query"])
                    continue
                msg = u.get("message") or {}
                chat_id = str(msg.get("chat", {}).get("id", ""))
                if chat_id not in ALLOWED:
                    continue
                if "document" in msg:
                    handle_document(chat_id, msg)
                    continue
                handle_text(chat_id, (msg.get("text") or "").strip())
        except Exception:
            time.sleep(5)


if __name__ == "__main__":
    main()
