#!/usr/bin/env bash
# Проверка репозитория 321r: синтаксис кода, ссылки документации, чистота от
# артефактов разработки. Запуск: bash tools/check.sh  (локально и в CI).
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

echo "== bash -n =="
while IFS= read -r f; do
  if bash -n "$f"; then :; else echo "  FAIL $f"; fail=1; fi
done < <(find install scripts deploy tools -name '*.sh' -type f | sort)
[ "$fail" = 0 ] && echo "  ok"

echo "== python =="
if python3 -m compileall -q scripts tools; then echo "  ok"; else fail=1; fi
rm -rf scripts/__pycache__ tools/__pycache__

echo "== ссылки документации =="
bad=0
for f in docs/*.md README.md; do
  [ -f "$f" ] || continue
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    case "$link" in *.md) ;; *) continue ;; esac
    target="$link"
    case "$f" in docs/*) case "$link" in docs/*) ;; *) target="docs/$link" ;; esac ;; esac
    if [ ! -f "$target" ]; then echo "  $f -> $link (нет файла)"; bad=1; fi
  done < <(grep -oE '\]\([A-Za-z0-9./_-]+\)' "$f" | sed 's/](\(.*\))/\1/')
done
[ "$bad" = 0 ] && echo "  ok" || fail=1

echo "== чистота от артефактов разработки =="
bad=0
hits="$(grep -rn --exclude=check.sh -E "V1/|PLAN\.md|llm_memoru|полев[а-я]* тест|inventory-debug" \
        README.md docs install scripts systemd deploy cron.d apps.d swarm stacks tools 2>/dev/null | head -5)"
if [ -n "$hits" ]; then echo "$hits"; bad=1; fi
[ "$bad" = 0 ] && echo "  ok" || fail=1

echo "== секреты не в репозитории =="
bad=0
if git ls-files 2>/dev/null | grep -E '(^|/)(secrets/[^.]|servers\.pw|id_cluster|.*\.pem$|.*\.key$|inventory\.conf$)'; then
  bad=1
fi
[ "$bad" = 0 ] && echo "  ok" || fail=1

echo
if [ "$fail" = 0 ]; then echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"; exit 0; fi
echo "ЕСТЬ ЗАМЕЧАНИЯ"; exit 1
