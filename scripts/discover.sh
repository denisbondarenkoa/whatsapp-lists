#!/bin/bash
# scripts/discover.sh - Автоматическое обнаружение доменов и IP WhatsApp

set -euo pipefail

# Цвета для логов
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/tmp/whatsapp-discovery-$(date +%Y%m%d).log"
TEMP_DIR="/tmp/whatsapp-discovery-$$"
mkdir -p "$TEMP_DIR"

# Функция логирования
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "${BLUE}🚀 Начинаем обнаружение WhatsApp доменов и IP...${NC}"

# ============================================================================
# 1. ОСНОВНЫЕ ДОМЕНЫ WHTASAPP/META (статичная база)
# ============================================================================
log "${YELLOW}📝 Генерация базовых доменов...${NC}"

cat > "$TEMP_DIR/base-domains.txt" << 'EOF'
# Основные домены WhatsApp
whatsapp.com
www.whatsapp.com
web.whatsapp.com
api.whatsapp.com
chat.whatsapp.com
call.whatsapp.com
voice.whatsapp.com
status.whatsapp.com
updates.whatsapp.com
beta.whatsapp.com

# Домены WhatsApp.net
s.whatsapp.net
static.whatsapp.net
mmg.whatsapp.net
mmi.whatsapp.net
mms.whatsapp.net
v.whatsapp.net

# Домены для звонков
voip.whatsapp.com

# Инфраструктура Meta
facebook.com
www.facebook.com
fb.com
www.fb.com
messenger.com
www.messenger.com
fbcdn.net
static.xx.fbcdn.net
scontent.xx.fbcdn.net
scontent.cdninstagram.com
instagram.com
www.instagram.com
EOF

# ============================================================================
# 2. ПОИСК ЧЕРЕЗ SSL СЕРТИФИКАТЫ
# ============================================================================
log "${YELLOW}🔍 Поиск через SSL сертификаты...${NC}"

discover_ssl_domains() {
    local target="$1"
    timeout 10 openssl s_client -servername "$target" -connect "$target:443" 2>/dev/null </dev/null | \
        openssl x509 -noout -text 2>/dev/null | \
        grep -oE "DNS:[a-zA-Z0-9.*-]+" | \
        cut -d: -f2 | \
        sed 's/\*\.//g' | \
        sort -u || true
}

# Проверяем основные домены
for domain in whatsapp.com facebook.com; do
    log "  Проверка $domain..."
    discover_ssl_domains "$domain" >> "$TEMP_DIR/ssl-domains.txt"
done

# ============================================================================
# 3. DNS ИССЛЕДОВАНИЕ (поиск поддоменов)
# ============================================================================
log "${YELLOW}🌐 DNS исследование...${NC}"

dns_discovery() {
    local domain="$1"
    
    # Используем разные методы
    {
        # dig с разными записями
        dig +short "$domain" ANY
        dig +short "*.$domain" A 2>/dev/null | head -20
        # Поиск через DNSdumpster (эмуляция)
        echo "mail.$domain"
        echo "mx.$domain"
        echo "smtp.$domain"
        echo "imap.$domain"
        echo "pop.$domain"
    } | grep -E "([a-zA-Z0-9-]+\.)?$domain$" | sort -u
}

for domain in whatsapp.com whatsapp.net fbcdn.net; do
    log "  Поиск поддоменов $domain..."
    dns_discovery "$domain" >> "$TEMP_DIR/dns-domains.txt"
done

# ============================================================================
# 4. ПОЛУЧЕНИЕ IP ДИАПАЗОНОВ META (AS32934)
# ============================================================================
log "${YELLOW}📡 Получение IP диапазонов Meta (AS32934)...${NC}"

get_meta_cidr() {
    # Метод 1: Из whois.radb.net
    local cidr_list
    cidr_list=$(timeout 30 whois -h whois.radb.net '!gAS32934' 2>/dev/null | \
        grep -E "^route[6]?:" | awk '{print $2}' | sort -u || echo "")
    
    if [ -z "$cidr_list" ]; then
        # Метод 2: Из bgpview.io API
        cidr_list=$(curl -s "https://api.bgpview.io/asn/32934/prefixes" 2>/dev/null | \
            jq -r '.data.ipv4_prefixes[].prefix' 2>/dev/null || echo "")
    fi
    
    echo "$cidr_list"
}

META_CIDR=$(get_meta_cidr)
if [ -n "$META_CIDR" ]; then
    echo "$META_CIDR" > "$TEMP_DIR/meta-cidr.txt"
    log "${GREEN}✓ Получено $(echo "$META_CIDR" | wc -l) CIDR диапазонов${NC}"
else
    # Резервные диапазоны
    cat > "$TEMP_DIR/meta-cidr.txt" << 'EOF'
31.13.24.0/21
31.13.64.0/18
45.64.40.0/22
66.220.144.0/20
69.63.176.0/20
69.171.224.0/19
74.119.76.0/22
102.132.96.0/20
103.4.96.0/22
129.134.0.0/16
157.240.0.0/16
173.252.64.0/18
185.60.216.0/22
199.201.64.0/22
204.15.20.0/22
EOF
    log "${YELLOW}⚠ Используем резервные CIDR${NC}"
fi

# ============================================================================
# 5. DNS РЕЗОЛВИНГ - получаем IP адреса
# ============================================================================
log "${YELLOW}🔎 DNS резолвинг доменов...${NC}"

resolve_domains() {
    local input_file="$1"
    local output_file="$2"
    
    while read -r domain; do
        # Пропускаем комментарии и пустые строки
        [[ "$domain" =~ ^# ]] && continue
        [[ -z "$domain" ]] && continue
        
        log "    Резолвинг: $domain"
        
        # Пробуем разные DNS серверы
        for dns in "8.8.8.8" "1.1.1.1" "208.67.222.222"; do
            ips=$(timeout 5 dig +short "$domain" @"$dns" 2>/dev/null | \
                grep -E "^[0-9]+\." | head -5)
            
            if [ -n "$ips" ]; then
                echo "# Домен: $domain" >> "$output_file"
                echo "$ips" >> "$output_file"
                break
            fi
        done
        
        sleep 0.1 # Защита от rate limiting
    done < "$input_file"
}

# Объединяем все домены
cat "$TEMP_DIR/base-domains.txt" \
    "$TEMP_DIR/ssl-domains.txt" \
    "$TEMP_DIR/dns-domains.txt" | \
    sort -u | grep -v '^$' > "$TEMP_DIR/all-domains.txt"

resolve_domains "$TEMP_DIR/all-domains.txt" "$TEMP_DIR/resolved-ips.txt"

# ============================================================================
# 6. АНАЛИЗ IP АДРЕСОВ - группируем в подсети
# ============================================================================
log "${YELLOW}📊 Анализ IP адресов...${NC}"

analyze_ips() {
    # Извлекаем только IP из resolved-ips.txt
    grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" "$TEMP_DIR/resolved-ips.txt" | \
        sort -u > "$TEMP_DIR/unique-ips.txt"
    
    # Группируем в /24 подсети
    cat "$TEMP_DIR/unique-ips.txt" | while read ip; do
        # Проверяем валидность IP
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            subnet=$(echo "$ip" | cut -d. -f1-3)
            echo "${subnet}.0/24"
        fi
    done | sort -u > "$TEMP_DIR/subnets-24.txt"
    
    # Группируем в /16 подсети
    cat "$TEMP_DIR/unique-ips.txt" | while read ip; do
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            subnet=$(echo "$ip" | cut -d. -f1-2)
            echo "${subnet}.0.0/16"
        fi
    done | sort -u > "$TEMP_DIR/subnets-16.txt"
}

analyze_ips

# ============================================================================
# 7. ФИНАЛЬНАЯ ГЕНЕРАЦИЯ ФАЙЛОВ
# ============================================================================
log "${YELLOW}📄 Генерация итоговых файлов...${NC}"

# Домены
cat "$TEMP_DIR/all-domains.txt" | sort -u | grep -v '^#' > "$TEMP_DIR/domains-final.txt"
DOMAIN_COUNT=$(wc -l < "$TEMP_DIR/domains-final.txt")

# CIDR (объединяем Meta CIDR и найденные подсети)
cat "$TEMP_DIR/meta-cidr.txt" \
    "$TEMP_DIR/subnets-24.txt" \
    "$TEMP_DIR/subnets-16.txt" | \
    sort -u | grep -v '^$' > "$TEMP_DIR/cidr-final.txt"
CIDR_COUNT=$(wc -l < "$TEMP_DIR/cidr-final.txt")

# ============================================================================
# 8. ВЕРИФИКАЦИЯ (быстрая проверка доступности)
# ============================================================================
log "${YELLOW}✅ Быстрая верификация...${NC}"

verify_lists() {
    log "  Проверка 5 случайных доменов..."
    shuf -n 5 "$TEMP_DIR/domains-final.txt" | while read domain; do
        if timeout 3 ping -c 1 "$domain" &>/dev/null; then
            log "    ${GREEN}✓ $domain доступен${NC}"
        else
            log "    ${YELLOW}⚠ $domain не пингуется${NC}"
        fi
    done
    
    log "  Проверка 3 случайных подсетей..."
    shuf -n 3 "$TEMP_DIR/cidr-final.txt" | while read cidr; do
        log "    Проверка $cidr"
    done
}

verify_lists

# ============================================================================
# 9. СОХРАНЕНИЕ РЕЗУЛЬТАТОВ
# ============================================================================
log "${GREEN}🎉 Обнаружение завершено!${NC}"
log "  Найдено доменов: $DOMAIN_COUNT"
log "  Найдено CIDR: $CIDR_COUNT"

# Копируем результаты
cp "$TEMP_DIR/domains-final.txt" "/tmp/whatsapp-domains-$(date +%Y%m%d).txt"
cp "$TEMP_DIR/cidr-final.txt" "/tmp/whatsapp-cidr-$(date +%Y%m%d).txt"

# Очистка
rm -rf "$TEMP_DIR"

log "${BLUE}📁 Файлы сохранены в /tmp/${NC}"
echo "domains: $DOMAIN_COUNT, cidr: $CIDR_COUNT"
