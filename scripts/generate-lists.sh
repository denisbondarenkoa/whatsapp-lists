#!/bin/bash
# scripts/generate-lists.sh - Финальная генерация оптимизированных списков
# Запускается после discover.sh для создания clean-файлов

set -euo pipefail

# Конфигурация
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LISTS_DIR="$PROJECT_ROOT/lists"
WORK_DIR="/tmp/whatsapp-generate-$$"
mkdir -p "$WORK_DIR"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

# ============================================================================
# 1. ПОДГОТОВКА - копируем сырые данные
# ============================================================================
log "Подготовка данных..."

# Берем результаты из discover.sh или из последнего запуска
if [ -f "/tmp/whatsapp-domains-*.txt" ] 2>/dev/null; then
    cp /tmp/whatsapp-domains-*.txt "$WORK_DIR/raw-domains.txt" 2>/dev/null || true
    cp /tmp/whatsapp-cidr-*.txt "$WORK_DIR/raw-cidr.txt" 2>/dev/null || true
fi

# Если нет свежих данных, берем из lists/
if [ ! -f "$WORK_DIR/raw-domains.txt" ] || [ ! -s "$WORK_DIR/raw-domains.txt" ]; then
    if [ -f "$LISTS_DIR/domains.txt" ]; then
        cp "$LISTS_DIR/domains.txt" "$WORK_DIR/raw-domains.txt"
    else
        echo "# Базовые домены WhatsApp" > "$WORK_DIR/raw-domains.txt"
        echo "whatsapp.com" >> "$WORK_DIR/raw-domains.txt"
        echo "web.whatsapp.com" >> "$WORK_DIR/raw-domains.txt"
    fi
fi

if [ ! -f "$WORK_DIR/raw-cidr.txt" ] || [ ! -s "$WORK_DIR/raw-cidr.txt" ]; then
    if [ -f "$LISTS_DIR/cidr.txt" ]; then
        cp "$LISTS_DIR/cidr.txt" "$WORK_DIR/raw-cidr.txt"
    else
        echo "# Базовые CIDR Meta" > "$WORK_DIR/raw-cidr.txt"
        echo "31.13.24.0/21" >> "$WORK_DIR/raw-cidr.txt"
        echo "157.240.0.0/16" >> "$WORK_DIR/raw-cidr.txt"
    fi
fi

# ============================================================================
# 2. ОЧИСТКА ДОМЕНОВ - удаляем дубли, невалидные
# ============================================================================
log "Очистка списка доменов..."

clean_domains() {
    local input="$1"
    local output="$2"
    
    # Удаляем:
    # 1. Комментарии
    # 2. Пустые строки
    # 3. Дубли
    # 4. Некорректные домены
    grep -v '^#' "$input" | \
        grep -v '^$' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        grep -E '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$' | \
        sort -u > "$output"
}

clean_domains "$WORK_DIR/raw-domains.txt" "$WORK_DIR/cleaned-domains.txt"

# ============================================================================
# 3. ОЧИСТКА CIDR - валидация подсетей
# ============================================================================
log "Очистка списка CIDR..."

clean_cidr() {
    local input="$1"
    local output="$2"
    
    # Удаляем комментарии и пустые строки
    grep -v '^#' "$input" | \
        grep -v '^$' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        # Проверяем валидность CIDR
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' | \
        # Фильтруем приватные и зарезервированные подсети
        grep -v -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|0\.|169\.254\.|224\.|240\.)' | \
        sort -u > "$output"
}

clean_cidr "$WORK_DIR/raw-cidr.txt" "$WORK_DIR/cleaned-cidr.txt"

# ============================================================================
# 4. ОПТИМИЗАЦИЯ - удаляем избыточные подсети
# ============================================================================
log "Оптимизация CIDR (удаление избыточных подсетей)..."

optimize_cidr() {
    local input="$1"
    local output="$2"
    
    # Сортируем по размеру маски (от меньшей к большей)
    # /8, /16, /24 и т.д.
    cat "$input" | while read cidr; do
        mask=$(echo "$cidr" | cut -d/ -f2)
        echo "$mask $cidr"
    done | sort -n | cut -d' ' -f2 > "$WORK_DIR/sorted-cidr.txt"
    
    # Простая оптимизация - оставляем только /24 и /16
    # Можно добавить более сложную логику с ipcalc
    cp "$WORK_DIR/sorted-cidr.txt" "$output"
    
    # Альтернатива: использовать aggregate для объединения подсетей
    if command -v aggregate &> /dev/null; then
        aggregate < "$input" > "$output" 2>/dev/null || true
    fi
}

optimize_cidr "$WORK_DIR/cleaned-cidr.txt" "$WORK_DIR/optimized-cidr.txt"

# ============================================================================
# 5. ПРОВЕРКА ДОСТУПНОСТИ (быстрая)
# ============================================================================
log "Быстрая проверка доступности..."

quick_check() {
    log "  Проверка 3 ключевых домена:"
    
    check_domain() {
        local domain="$1"
        if timeout 3 ping -c 1 "$domain" &>/dev/null; then
            echo -e "    ${GREEN}✓ $domain${NC}"
            return 0
        else
            # Пробуем через curl если ping не работает
            if timeout 3 curl -s -I "https://$domain" &>/dev/null; then
                echo -e "    ${GREEN}✓ $domain (через curl)${NC}"
                return 0
            else
                echo -e "    ${YELLOW}⚠ $domain недоступен${NC}"
                return 1
            fi
        fi
    }
    
    # Проверяем ключевые домены
    local test_domains=("web.whatsapp.com" "whatsapp.com" "s.whatsapp.net")
    local available=0
    
    for domain in "${test_domains[@]}"; do
        if grep -q -x "$domain" "$WORK_DIR/cleaned-domains.txt"; then
            if check_domain "$domain"; then
                ((available++))
            fi
        fi
    done
    
    if [ $available -ge 2 ]; then
        log "  ${GREEN}Доступность подтверждена ($available/3)${NC}"
        return 0
    else
        log "  ${YELLOW}Внимание: только $available из 3 доменов доступны${NC}"
        return 1
    fi
}

quick_check || log "${YELLOW}Предупреждение: некоторые домены могут быть недоступны${NC}"

# ============================================================================
# 6. СОЗДАНИЕ ВАРИАНТОВ ДЛЯ РАЗНЫХ СЦЕНАРИЕВ
# ============================================================================
log "Создание вариантов списков..."

# Вариант 1: Минимальный (только самое важное)
create_minimal_list() {
    local domains_input="$1"
    local cidr_input="$2"
    
    # Топ-10 доменов
    head -10 "$domains_input" > "$WORK_DIR/domains-minimal.txt"
    
    # Только основные CIDR Meta
    grep -E "^(31\.13\.|157\.240\.)" "$cidr_input" | head -5 > "$WORK_DIR/cidr-minimal.txt"
}

# Вариант 2: Полный (все что нашли)
create_full_list() {
    cp "$WORK_DIR/cleaned-domains.txt" "$WORK_DIR/domains-full.txt"
    cp "$WORK_DIR/optimized-cidr.txt" "$WORK_DIR/cidr-full.txt"
}

create_minimal_list "$WORK_DIR/cleaned-domains.txt" "$WORK_DIR/optimized-cidr.txt"
create_full_list

# ============================================================================
# 7. ФИНАЛЬНАЯ ГЕНЕРАЦИЯ - создаем файлы в lists/
# ============================================================================
log "Финальная генерация..."

mkdir -p "$LISTS_DIR"
mkdir -p "$LISTS_DIR/variants"

# Основные файлы (используются по умолчанию)
cp "$WORK_DIR/domains-full.txt" "$LISTS_DIR/domains.txt"
cp "$WORK_DIR/cidr-full.txt" "$LISTS_DIR/cidr.txt"

# Варианты
cp "$WORK_DIR/domains-minimal.txt" "$LISTS_DIR/variants/domains-minimal.txt"
cp "$WORK_DIR/cidr-minimal.txt" "$LISTS_DIR/variants/cidr-minimal.txt"
cp "$WORK_DIR/domains-full.txt" "$LISTS_DIR/variants/domains-full.txt"
cp "$WORK_DIR/cidr-full.txt" "$LISTS_DIR/variants/cidr-full.txt"

# Версии с комментариями для удобства
add_header() {
    local file="$1"
    local header="# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Source: WhatsApp Discovery Script
# Total entries: $(wc -l < "$file")
# Use in PodKop: Add as URL list
#
"
    echo -e "$header$(cat "$file")" > "${file}.tmp"
    mv "${file}.tmp" "$file"
}

add_header "$LISTS_DIR/domains.txt"
add_header "$LISTS_DIR/cidr.txt"

# ============================================================================
# 8. СТАТИСТИКА И ЛОГИРОВАНИЕ
# ============================================================================
log "Генерация статистики..."

STATS_FILE="$LISTS_DIR/stats.json"
cat > "$STATS_FILE" << EOF
{
  "generated": "$(date -Iseconds)",
  "domains": {
    "total": $(wc -l < "$LISTS_DIR/domains.txt"),
    "minimal": $(wc -l < "$LISTS_DIR/variants/domains-minimal.txt"),
    "full": $(wc -l < "$LISTS_DIR/variants/domains-full.txt")
  },
  "cidr": {
    "total": $(wc -l < "$LISTS_DIR/cidr.txt"),
    "minimal": $(wc -l < "$LISTS_DIR/variants/cidr-minimal.txt"),
    "full": $(wc -l < "$LISTS_DIR/variants/cidr-full.txt")
  },
  "source": "github.com/$(git config --get remote.origin.url 2>/dev/null | sed 's/.*github.com\///;s/\.git$//' || echo 'unknown')"
}
EOF

# Человекочитаемая статистика
echo "# 📊 Статистика WhatsApp Lists
" > "$LISTS_DIR/README.md"

echo "## Последнее обновление: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LISTS_DIR/README.md"
echo "" >> "$LISTS_DIR/README.md"
echo "### Основные списки:" >> "$LISTS_DIR/README.md"
echo "- **Домены:** $(wc -l < "$LISTS_DIR/domains.txt") записей" >> "$LISTS_DIR/README.md"
echo "- **CIDR:** $(wc -l < "$LISTS_DIR/cidr.txt") записей" >> "$LISTS_DIR/README.md"
echo "" >> "$LISTS_DIR/README.md"
echo "### Варианты:" >> "$LISTS_DIR/README.md"
echo "- **Минимальный:** $(wc -l < "$LISTS_DIR/variants/domains-minimal.txt") доменов, $(wc -l < "$LISTS_DIR/variants/cidr-minimal.txt") CIDR" >> "$LISTS_DIR/README.md"
echo "- **Полный:** $(wc -l < "$LISTS_DIR/variants/domains-full.txt") доменов, $(wc -l < "$LISTS_DIR/variants/cidr-full.txt") CIDR" >> "$LISTS_DIR/README.md"
echo "" >> "$LISTS_DIR/README.md"
echo "### Использование в PodKop:" >> "$LISTS_DIR/README.md"
echo '```' >> "$LISTS_DIR/README.md"
echo "Домены: https://raw.githubusercontent.com/KharunDima/whatsapp-lists/main/lists/domains.txt" >> "$LISTS_DIR/README.md"
echo "CIDR: https://raw.githubusercontent.com/KharunDima/whatsapp-lists/main/lists/cidr.txt" >> "$LISTS_DIR/README.md"
echo '```' >> "$LISTS_DIR/README.md"

# ============================================================================
# 9. ЗАВЕРШЕНИЕ
# ============================================================================
DOMAIN_COUNT=$(wc -l < "$LISTS_DIR/domains.txt")
CIDR_COUNT=$(wc -l < "$LISTS_DIR/cidr.txt")

log "${GREEN}✅ Генерация завершена!${NC}"
log "  📁 Результаты в: $LISTS_DIR/"
log "  📊 Статистика:"
log "     • Домены: $DOMAIN_COUNT"
log "     • CIDR: $CIDR_COUNT"
log "     • Варианты: минимальный, полный"
log ""
log "${YELLOW}🚀 Для использования в PodKop:${NC}"
log "  Домены: https://raw.githubusercontent.com/KharunDima/whatsapp-lists/main/lists/domains.txt"
log "  CIDR: https://raw.githubusercontent.com/KharunDima/whatsapp-lists/main/lists/cidr.txt"

# Очистка
rm -rf "$WORK_DIR"
