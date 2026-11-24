# 321r — отказоустойчивый кластер VPS одной командой

321r собирает из списка обычных VPS рабочий кластер: серверы связываются зашифрованным
мешем, сервисы запускаются в Docker Swarm, базы данных реплицируются между серверами и
сами восстанавливаются после отказов, доступ к панелям идёт через Pangolin, VPN и обход
блокировок — через Remnawave. Установка — одна команда с первого сервера, дальше мастер
спрашивает только адреса, пароли и токены.

Серверы можно терять, менять и добавлять: кластер собирается заново по инструкции, а
данные переживают отказ одного или двух серверов.

## Что получается

| Слой | Что даёт |
|---|---|
| Меш AmneziaWG | зашифрованный канал между всеми серверами (N×N), трафик БД и служб не ходит по интернету |
| Docker Swarm | запуск и переселение сервисов, кворум для решений о первичной БД |
| Слой БД | PostgreSQL и MongoDB с репликацией по приложениям, единый адрес `10.66.0.99:<порт>`, автоназначение первичного и фенсинг изолированных серверов |
| Pangolin | доступ к панелям и сайтам с wildcard-сертификатами, health-check целей, агенты Newt на каждом сервере |
| Komodo | управление серверами и стеками |
| Remnawave | VPN для пользователей, страница подписки, маскировка трафика (в том числе для Telegram), WARP-обход |
| Zabbix 7.0 LTS | мониторинг кластера в режиме HA, метрики собственного кластера |
| Telegram-бот | команды, алерты с готовыми действиями, утренний дайджест, памятка владельца |
| Бэкапы | ежедневные снимки по правилу 3-2-1, проверка восстановлением, маяк свежести |

## Требования

- **От 3 серверов** (минимум для кворума; количество ограничено только бюджетом памяти).
- Debian 12+ или Ubuntu 22.04+, root-доступ по ssh и паролю или ключу.
- Полная виртуализация (KVM или bare metal): контейнерные виртуализации (OpenVZ, LXC)
  не подходят — не встанет AmneziaWG.
- Память: от 1 ГБ на сервер (профиль S — только ядро), полный состав с панелями и
  базами требует один сервер от 4 ГБ. Подробно — [docs/resources.md](docs/resources.md).
- Домен в Cloudflare и API-токен (для сертификатов и DDNS).

## Установка

Запустите от root на **первом** сервере:

```bash
curl -fsSL https://raw.githubusercontent.com/fdcdsf/321r-Alpha/master/install/bootstrap.sh | bash
```

Если `curl` не установлен (свежая Debian), либо поставьте его
(`apt-get update && apt-get install -y curl`), либо запустите через wget:

```bash
wget -qO- https://raw.githubusercontent.com/fdcdsf/321r-Alpha/master/install/bootstrap.sh | bash
```

Мастер спросит количество серверов, их имена и адреса, токен Telegram-бота, домен,
Cloudflare-токен, режим Remnawave, профиль ресурсов и нужен ли Zabbix. Остальное
установщик сделает сам: подготовит все серверы, соберёт меш и Swarm, поднимет базы,
панели, VPN, выдаст сертификаты и проверит результат автоприёмкой.

Важное:

- **Установка переживает обрыв ssh.** После вопросов мастера шаги идут в фоне;
  лог — `/var/log/321r-install.log`, следить: `tail -f /var/log/321r-install.log`.
- Прерванная установка продолжается с любого шага: `bash install/install.sh --from=mesh`.
- Секреты (пароли баз, ключи, лицензии) генерируются автоматически и складываются в
  `install/secrets/` и `/etc/db/secrets/`; в репозиторий они не попадают.
- В конце придёт **памятка владельца** в Telegram: все пароли, ключи и ссылки одним
  файлом (копия на сервере — `/root/321r-pamyatka-*.txt`).

Проверка готовой системы:

```bash
cd /opt/321r && bash install/install.sh --check
```

Если что-то не так — соберите диагностику одним файлом и приложите её к обращению
(секреты в неё не попадают):

```bash
/usr/local/bin/321r-doctor.sh
```

Отказоустойчивость проверяется учениями — большинство из них прогоняются сами:

```bash
/usr/local/bin/321r-drills.sh list          # каталог дриллов и нормы
/usr/local/bin/321r-drills.sh run all --yes # прогон обычных дриллов
```

## Документация

| Задача | Документ |
|---|---|
| Быстро попробовать и понять, что происходит | [docs/quickstart.md](docs/quickstart.md) |
| Как устроен кластер | [docs/architecture.md](docs/architecture.md) |
| Развернуть всё с нуля | [docs/deploy.md](docs/deploy.md) |
| Добавить сервер в кластер | [docs/add-node.md](docs/add-node.md) |
| Убрать лишний сервер | [docs/remove-node.md](docs/remove-node.md) |
| Заменить сгоревший или заблокированный сервер | [docs/replace-node.md](docs/replace-node.md) |
| Домены, сертификаты, DNS | [docs/dns-and-tls.md](docs/dns-and-tls.md) |
| Базы данных, репликация, фейловер | [docs/databases.md](docs/databases.md) |
| Бэкапы и восстановление | [docs/backups.md](docs/backups.md) |
| Правило 3-2-1 и аварийный режим | [docs/doctrine-3-2-1.md](docs/doctrine-3-2-1.md) |
| Мониторинг и алерты | [docs/monitoring.md](docs/monitoring.md) |
| Безопасность | [docs/security.md](docs/security.md) |
| Zabbix | [docs/zabbix.md](docs/zabbix.md) |
| Эксплуатация и сценарии отказов | [docs/operations.md](docs/operations.md) |
| Что-то сломалось: поиск по симптому | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Команды и API | [docs/api.md](docs/api.md) |
| Учения по отказам | [docs/drills.md](docs/drills.md) |
| VPN и маскировка | [docs/vpn.md](docs/vpn.md) |
| Меш AmneziaWG | [docs/amnezia-wg.md](docs/amnezia-wg.md) |
| Pangolin: сертификаты и ресурсы | [docs/pangolin.md](docs/pangolin.md) |
| Профили ресурсов и минимумы железа | [docs/resources.md](docs/resources.md) |
| Порт, путь, служба — где что лежит | [docs/reference.md](docs/reference.md) |
| Непонятно слово | [docs/glossary.md](docs/glossary.md) |

## Устройство репозитория

```
install/     установщик: bootstrap.sh (точка входа), install.sh (шаги), lib.sh и шаги по слоям
scripts/     команды, которые живут на серверах кластера (БД, бэкапы, бот, VPN, проверки)
systemd/     службы и таймеры кластера (awg0, db-guard, docker-user, reresolve-dns, tgbot)
deploy/      шаблоны развёртывания: Pangolin, Remnawave, Zabbix
stacks/      одиночные стеки (Valkey), swarm/ — swarm-стеки (Komodo, Uptime Kuma)
apps.d/      примеры записей реестра баз данных
docs/        руководство пользователя
```

## Лицензия

[MIT](LICENSE)
