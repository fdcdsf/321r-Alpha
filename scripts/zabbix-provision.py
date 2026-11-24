#!/usr/bin/env python3
"""Идемпотентная настройка Zabbix API: админ, агенты, LLD сервисов, HA, алерты.

Запуск на control: --url http://127.0.0.1:8081 --node a:10.66.0.1 ... --control a
Пароль Admin и пароль служебного бота — только в защищённой /etc/db/secrets.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import sys
import urllib.error
import urllib.request


class Failure(Exception):
    pass


class Api:
    def __init__(self, url):
        if not re.fullmatch(r'http://127\.0\.0\.1:[0-9]{1,5}', url):
            raise Failure('API Zabbix должен быть только на локальном loopback')
        self.url = url + '/api_jsonrpc.php'
        self.token = None
        self.counter = 0

    def call(self, method, params):
        self.counter += 1
        headers = {'Content-Type': 'application/json-rpc'}
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        body = json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params,
                           'id': self.counter}).encode()
        try:
            request = urllib.request.Request(self.url, data=body, headers=headers)
            with urllib.request.urlopen(request, timeout=25) as response:
                data = json.load(response)
        except (urllib.error.URLError, TimeoutError) as exc:
            raise Failure(f'{method}: API недоступен ({type(exc).__name__})') from None
        if 'error' in data:
            # Не выводить error.data: сервер может отразить поля запроса.
            # Исключение — диагностика схемы действий (секретов в них нет).
            if method in ('action.create', 'action.update', 'mediatype.create',
                          'mediatype.update', 'user.create', 'user.update',
                          'usergroup.create', 'item.create', 'trigger.create'):
                raise Failure(f'{method}: {data["error"].get("data", "API error")[:250]}')
            raise Failure(f'{method}: {data["error"].get("message", "API error")}')
        return data.get('result')


def login(api, path):
    path = Path(path)
    if path.exists():
        if os.name == 'posix' and path.stat().st_mode & 0o077:
            raise Failure('права файла администратора шире 600')
        password = json.loads(path.read_text(encoding='utf-8'))['password']
        api.token = api.call('user.login', {'username': 'Admin', 'password': password})
        return
    # Файла нет: либо первичная настройка, либо запуск не с control-ноды.
    # Сначала пробуем пароль по умолчанию; если он не подходит — НЕ создаём файл,
    # чтобы не оставить битый секрет (и не пытаться менять пароль вслепую).
    try:
        api.token = api.call('user.login', {'username': 'Admin', 'password': 'zabbix'})
    except Failure:
        raise Failure('файла админа нет, а пароль по умолчанию не подходит: '
                      'запустите провизию с control-ноды (там лежит /etc/db/secrets/zabbix-admin.json)') from None
    password = 'Aa1!' + secrets.token_urlsafe(30)
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump({'username': 'Admin', 'password': password}, f)
    admins = api.call('user.get', {'filter': {'username': ['Admin']}, 'output': ['userid']})
    if len(admins) != 1:
        raise Failure('Admin не найден в Zabbix')
    api.call('user.update', {'userid': admins[0]['userid'], 'passwd': password,
                             'current_passwd': 'zabbix'})
    api.token = api.call('user.login', {'username': 'Admin', 'password': password})
    print('Zabbix: пароль Admin заменён, сохранён только в защищённом файле')


def one(api, method, name, idfield, create, params):
    got = api.call(method + '.get', {'filter': {'name' if method in ('hostgroup', 'templategroup') else 'host': [name]},
                                    'output': [idfield]})
    if got:
        return got[0][idfield]
    return api.call(method + '.create', params)[idfield + 's'][0]


def clean_default_host(api, linux_id):
    """На хосте по умолчанию 'Zabbix server' нет агента: снимаем шаблон Linux,
    иначе триггер availability даёт вечную ложную тревогу."""
    default = api.call('host.get', {'filter': {'host': ['Zabbix server']}, 'output': ['hostid']})
    if not default:
        return
    try:
        api.call('host.update', {'hostid': default[0]['hostid'],
                                 'templates_clear': [{'templateid': linux_id}]})
        print('Zabbix: с хоста по умолчанию снят шаблон Linux (агента на нём нет)')
    except Failure as exc:
        print(f'Zabbix: не удалось снять Linux с хоста по умолчанию: {exc}')


def ensure_ha(api, control):
    """Состояние HA в общей БД: 3 = active, 0 = standby. Только на control."""
    hosts = api.call('host.get', {'filter': {'host': [control]}, 'output': ['hostid']})
    if len(hosts) != 1:
        raise Failure(f'{control}: хост не найден для элементов HA')
    hostid = hosts[0]['hostid']
    for key, name in (('cluster.ha.active', 'Zabbix HA: число активных серверов'),
                      ('cluster.ha.standby', 'Zabbix HA: число резервных узлов')):
        got = api.call('item.get', {'hostids': [hostid], 'filter': {'key_': [key]}, 'output': ['itemid', 'value_type']})
        if got:
            if got[0].get('value_type') != '0':
                api.call('item.update', {'itemid': got[0]['itemid'], 'value_type': 0})
        else:
            api.call('item.create', {'hostid': hostid, 'name': name, 'key_': key,
                                     'type': 7, 'value_type': 0, 'delay': '1m'})
    triggers = (
        ('Zabbix HA: нет ровно одного активного сервера',
         f'last(/{control}/cluster.ha.active)<>1', 4),
        ('Zabbix HA: нет резервного узла',
         f'last(/{control}/cluster.ha.standby)=0', 2),
    )
    for desc, expr, prio in triggers:
        got = api.call('trigger.get', {'hostids': [hostid], 'filter': {'description': [desc]},
                                       'output': ['triggerid']})
        if not got:
            api.call('trigger.create', {'description': desc, 'expression': expr, 'priority': prio})
    print(f'Zabbix: HA-элементы и триггеры на {control}')


def ensure_telegram(api, group, admin_file):
    """Алерты в тот же бот 321r. Отдельный пользователь НЕ в группе
    'Zabbix administrators', чтобы встроенное действие не дублировало сообщения."""
    params = {
        'name': '321r Telegram', 'type': 1, 'exec_path': 'tg-relay.sh', 'status': 0,
        'maxattempts': 3, 'attempt_interval': '10s',
        'parameters': [
            {'sortorder': 0, 'value': '{ALERT.SENDTO}'},
            {'sortorder': 1, 'value': '{ALERT.SUBJECT}'},
            {'sortorder': 2, 'value': '{ALERT.MESSAGE}'},
        ],
        'message_templates': [
            {'eventsource': 0, 'recovery': 0, 'subject': '321r: {EVENT.NAME}',
             'message': 'Хост: {HOST.NAME}\nСерьёзность: {EVENT.SEVERITY}\n'
                        'Время: {EVENT.DATE} {EVENT.TIME}\n{TRIGGER.URL}'},
            {'eventsource': 0, 'recovery': 1, 'subject': '321r: восстановлено {EVENT.RECOVERY.NAME}',
             'message': 'Проблема решена: {EVENT.RECOVERY.NAME}\nХост: {HOST.NAME}\n'
                        'Время: {EVENT.RECOVERY.DATE} {EVENT.RECOVERY.TIME}'},
        ],
    }
    mt = api.call('mediatype.get', {'filter': {'name': ['321r Telegram']}, 'output': ['mediatypeid']})
    if mt:
        mtid = mt[0]['mediatypeid']
        api.call('mediatype.update', {'mediatypeid': mtid, 'status': 0,
                                      'exec_path': 'tg-relay.sh',
                                      'parameters': params['parameters'],
                                      'message_templates': params['message_templates']})
    else:
        mtid = api.call('mediatype.create', params)['mediatypeids'][0]

    grp = api.call('usergroup.get', {'filter': {'name': ['321r alerts']}, 'output': ['usrgrpid']})
    if grp:
        grpid = grp[0]['usrgrpid']
    else:
        grpid = api.call('usergroup.create', {'name': '321r alerts', 'gui_access': 0})['usrgrpids'][0]

    bot_file = Path(str(admin_file).rsplit('/', 1)[0] + '/zabbix-bot-pass.json')
    user = api.call('user.get', {'filter': {'username': ['321r-bot']}, 'output': ['userid']})
    if user:
        uid = user[0]['userid']
    else:
        if bot_file.exists() and os.name == 'posix' and bot_file.stat().st_mode & 0o077:
            raise Failure('права файла пароля бота шире 600')
        password = (json.loads(bot_file.read_text(encoding='utf-8'))['password']
                    if bot_file.exists() else 'Aa1!' + secrets.token_urlsafe(30))
        if not bot_file.exists():
            bot_file.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            fd = os.open(bot_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                json.dump({'username': '321r-bot', 'password': password}, f)
        uid = api.call('user.create', {'username': '321r-bot', 'passwd': password,
                                       'roleid': 3, 'usrgrps': [{'usrgrpid': grpid}]})['userids'][0]
    medias = api.call('user.get', {'userid': uid, 'selectMedias': ['mediaid', 'mediatypeid'],
                                   'output': ['userid']})
    if not any(m['mediatypeid'] == mtid for m in medias[0].get('medias', [])):
        api.call('user.update', {'userid': uid, 'medias': [{
            'mediatypeid': mtid, 'sendto': '321r', 'active': 0, 'severity': 63,
            'period': '1-7,00:00-24:00'}]})

    action = api.call('action.get', {'filter': {'name': ['321r: алерты в Telegram']},
                                     'output': ['actionid']})
    ap = {
        'name': '321r: алерты в Telegram', 'eventsource': 0, 'status': 0, 'esc_period': '1h',
        'filter': {'evaltype': 0, 'conditions': [
            {'conditiontype': 0, 'operator': 0, 'value': group},
            {'conditiontype': 4, 'operator': 5, 'value': 3},
        ]},
        'operations': [{
            'operationtype': 0, 'esc_period': '0s', 'esc_step_from': 1, 'esc_step_to': 1,
            'evaltype': 0,
            'opmessage': {'default_msg': 1, 'mediatypeid': mtid},
            'opmessage_usr': [{'userid': uid}],
        }],
        'recovery_operations': [{
            'operationtype': 0,
            'opmessage': {'default_msg': 1, 'mediatypeid': mtid},
            'opmessage_usr': [{'userid': uid}],
        }],
    }
    if action:
        api.call('action.update', dict(ap, actionid=action[0]['actionid']))
    else:
        api.call('action.create', ap)
    print('Zabbix: алерты в Telegram 321r настроены (severity >= Average)')


def provision(api, nodes, control, admin_file):
    group = one(api, 'hostgroup', '321r', 'groupid', None, {'name': '321r'})
    template_group = one(api, 'templategroup', '321r', 'groupid', None, {'name': '321r'})
    custom = one(api, 'template', '321r services', 'templateid', None,
                 {'host': '321r services', 'groups': [{'groupid': template_group}]})
    rule = api.call('discoveryrule.get', {'hostids': [custom], 'filter': {'key_': ['cluster.services.discovery']},
                                         'output': ['itemid']})
    if rule:
        ruleid = rule[0]['itemid']
        api.call('discoveryrule.update', {'itemid': ruleid, 'lifetime': '1h'})
    else:
        ruleid = api.call('discoveryrule.create', {
            'name': '321r: Docker, systemd, базы', 'key_': 'cluster.services.discovery',
            'hostid': custom, 'type': 7, 'delay': '5m', 'lifetime': '1h',
        })['itemids'][0]
    prototype = api.call('itemprototype.get', {'discoveryids': [ruleid],
        'filter': {'key_': ['cluster.service.status[{#SERVICE}]']}, 'output': ['itemid']})
    if not prototype:
        api.call('itemprototype.create', {
            'name': '{#SERVICE} работает', 'key_': 'cluster.service.status[{#SERVICE}]',
            'hostid': custom, 'ruleid': ruleid, 'type': 7, 'value_type': 3, 'delay': '1m',
        })
    trig = api.call('triggerprototype.get', {'discoveryids': [ruleid], 'output': ['triggerid']})
    if not trig:
        api.call('triggerprototype.create', {'description': '{#SERVICE} недоступен',
            'expression': 'last(/321r services/cluster.service.status[{#SERVICE}])=0',
            'priority': 3})
    linux = api.call('template.get', {'filter': {'host': ['Linux by Zabbix agent active']},
                                      'output': ['templateid', 'host']})
    if len(linux) != 1:
        raise Failure('нет встроенного шаблона Linux by Zabbix agent active')
    linux_id = linux[0]['templateid']
    clean_default_host(api, linux_id)
    for name, ip in nodes:
        hosts = api.call('host.get', {'filter': {'host': [name]}, 'output': ['hostid']})
        if hosts:
            print(f'Zabbix: узел {name} уже зарегистрирован')
            continue
        api.call('host.create', {'host': name, 'name': '321r ' + name,
            'groups': [{'groupid': group}],
            'templates': [{'templateid': linux_id}, {'templateid': custom}],
            'interfaces': [{'type': 1, 'main': 1, 'useip': 1,
                            'ip': ip, 'dns': '', 'port': '10050'}]})
        print(f'Zabbix: узел {name} и оба шаблона добавлены')
    ensure_ha(api, control)
    # Новые узлы с HostMetadata=321r регистрируются без правки кода.
    action = api.call('action.get', {'filter': {'name': ['321r active agents']},
                                     'output': ['actionid']})
    if action:
        api.call('action.update', {'actionid': action[0]['actionid'], 'status': 0})
    else:
        api.call('action.create', {
            'name': '321r active agents', 'eventsource': 2, 'status': 0,
            'filter': {'evaltype': 0,
                       'conditions': [{'conditiontype': 24, 'operator': 2, 'value': '321r'}]},
            'operations': [
                {'operationtype': 4, 'opgroup': [{'groupid': group}]},
                {'operationtype': 6, 'optemplate': [
                    {'templateid': linux_id}, {'templateid': custom}]},
            ],
        })
        print('Zabbix: автодобавление новых агентов настроено')
    ensure_telegram(api, group, admin_file)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--url', default='http://127.0.0.1:8081')
    p.add_argument('--admin-file', default='/etc/db/secrets/zabbix-admin.json')
    p.add_argument('--node', action='append', required=True, help='alias:mesh-ip')
    p.add_argument('--control', required=True, help='alias контрольной ноды')
    args = p.parse_args()
    try:
        nodes = []
        import ipaddress
        for entry in args.node:
            name, ip = entry.split(':', 1)
            if not re.fullmatch(r'[a-z][a-z0-9-]{0,20}', name):
                raise Failure('неверное имя ноды')
            ipaddress.IPv4Address(ip)
            nodes.append((name, ip))
        api = Api(args.url)
        login(api, args.admin_file)
        provision(api, nodes, args.control, args.admin_file)
    except (Failure, ValueError, OSError, KeyError) as exc:
        print(f'Zabbix: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
