#!/usr/bin/env python3
"""Read-only приёмка Zabbix: HA, метрики хостов, discovery сервисов, алерты в Telegram."""
import argparse
import importlib.util
from pathlib import Path
import sys
import time

spec = importlib.util.spec_from_file_location('zabbix_provision', Path(__file__).with_name('zabbix-provision.py'))
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)


def check(api, nodes, control):
    ha = api.call('hanode.get', {'output': ['name', 'status', 'lastaccess']})
    active = [n for n in ha if n['status'] == '3']
    standby = [n for n in ha if n['status'] == '0']
    if len(active) != 1 or not standby:
        raise provision.Failure(f'HA: active={len(active)}, standby={len(standby)} (нужно 1 и >=1)')
    now = int(time.time())
    if any(now - int(n['lastaccess']) > 30 for n in active + standby):
        raise provision.Failure('HA: stale heartbeat')
    print(f'Zabbix HA: active={active[0]["name"]}, standby={len(standby)}')

    # Контрольная нода держит элементы HA — они должны быть свежими и корректными.
    control_host = api.call('host.get', {'filter': {'host': [control]}, 'output': ['hostid']})
    if len(control_host) != 1:
        raise provision.Failure(f'{control}: хост HA не найден')
    hid = control_host[0]['hostid']
    for key, want in (('cluster.ha.active', 1), ('cluster.ha.standby', 1)):
        items = api.call('item.get', {'hostids': [hid], 'filter': {'key_': [key]},
                                      'output': ['lastvalue', 'lastclock', 'state']})
        if not items:
            raise provision.Failure(f'{control}: нет элемента {key}')
        it = items[0]
        if int(it.get('lastclock') or 0) == 0 or now - int(it['lastclock']) > 300:
            raise provision.Failure(f'{control}: {key} не собирает данные')
        if it.get('state') != '0':
            raise provision.Failure(f'{control}: {key} в состоянии unsupported')
        if int(float(it['lastvalue'])) != want:
            raise provision.Failure(f'{control}: {key}={it["lastvalue"]}, ожидали {want}')
    print(f'{control}: HA-элементы актив=1, резерв=1')

    for alias in nodes:
        hosts = api.call('host.get', {'filter': {'host': [alias]}, 'output': ['hostid']})
        if len(hosts) != 1:
            raise provision.Failure(f'{alias}: host отсутствует в Zabbix')
        hostid = hosts[0]['hostid']
        uptime = api.call('item.get', {'hostids': [hostid], 'filter': {'key_': ['system.uptime']},
                                       'output': ['lastvalue', 'lastclock']})
        if not uptime or now - int(uptime[0].get('lastclock') or 0) > 900:
            raise provision.Failure(f'{alias}: нет свежей Linux-метрики uptime')
        items = api.call('item.get', {'hostids': [hostid], 'search': {'key_': 'cluster.service.status['},
                                      'output': ['key_', 'lastclock'], 'limit': 500})
        recent = sum(1 for x in items if now - int(x.get('lastclock') or 0) < 900)
        if recent < 3:
            raise provision.Failure(f'{alias}: активное обнаружение сервисов не собирает данные')
        kinds = {k['key_'].split('[', 1)[1].split('/', 1)[0] for k in items if '[' in k['key_']}
        if 'http' not in kinds:
            raise provision.Failure(f'{alias}: нет HTTP-проверок (своя VPN-маска)')
        print(f'{alias}: uptime, {recent} статусов сервисов и HTTP-проверка')

    # Кластерные проверки живут только на control — иначе алерты дублируются.
    citems = api.call('item.get', {'hostids': [hid], 'search': {'key_': 'cluster.service.status['},
                                   'output': ['key_'], 'limit': 500})
    ckinds = {i['key_'].split('[', 1)[1].split('/', 1)[0] for i in citems if '[' in i['key_']}
    for need, what in (('swarm', 'swarm-сервисы'), ('swarm-node', 'узлы swarm'),
                       ('vip', 'VIP приложений'), ('http', 'HTTP приложений')):
        if need not in ckinds:
            raise provision.Failure(f'{control}: нет кластерной проверки {what} ({need}/)')
    print(f'{control}: swarm, узлы swarm, VIP и HTTP приложений на наблюдении')

    # Алерты: медиатип-скрипт, служебный пользователь и действие должны быть готовы.
    mt = api.call('mediatype.get', {'filter': {'name': ['321r Telegram']},
                                    'output': ['mediatypeid', 'status', 'exec_path']})
    if not mt or mt[0]['status'] != '0' or not mt[0]['exec_path']:
        raise provision.Failure('нет включённого медиатипа 321r Telegram')
    user = api.call('user.get', {'filter': {'username': ['321r-bot']}, 'output': ['userid'],
                                 'selectMedias': ['mediaid', 'mediatypeid', 'active']})
    if not user or not user[0].get('medias'):
        raise provision.Failure('у 321r-bot нет медиа')
    if any(m['active'] != '0' for m in user[0]['medias']):
        raise provision.Failure('медиа 321r-bot отключено')
    act = api.call('action.get', {'filter': {'name': ['321r: алерты в Telegram']},
                                  'output': ['actionid', 'status']})
    if not act or act[0]['status'] != '0':
        raise provision.Failure('действие алертов 321r выключено')
    print('Алерты: медиатип 321r Telegram + пользователь 321r-bot + действие включены')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--admin-file', default='/etc/db/secrets/zabbix-admin.json')
    p.add_argument('--node', action='append', required=True)
    p.add_argument('--control', required=True)
    args = p.parse_args()
    try:
        api = provision.Api('http://127.0.0.1:8081')
        provision.login(api, args.admin_file)
        check(api, args.node, args.control)
    except (provision.Failure, ValueError, KeyError, OSError) as exc:
        print(f'Zabbix: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
