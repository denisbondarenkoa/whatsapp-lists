#!/bin/bash
# scripts/verify.sh - Проверка работоспособности списков

set -euo pipefail

echo "🔍 Проверка списков WhatsApp..."

# Проверяем домены
echo "1. Проверка доменов:"
head -10 lists/domains.txt | while read domain; do
    if dig +short "$domain" @8.8.8.8 >/dev/null 2>&1; then
        echo "  ✓ $domain"
    else
        echo "  ✗ $domain (не резолвится)"
    fi
done

# Проверяем CIDR
echo -e "\n2. Проверка CIDR:"
head -5 lists/cidr.txt | while read cidr; do
    echo "  📍 $cidr"
done

# Тест подключения к ключевым серверам
echo -e "\n3. Тест подключения:"
TEST_DOMAINS=("web.whatsapp.com" "whatsapp.com" "s.whatsapp.net")
for domain in "${TEST_DOMAINS[@]}"; do
    if timeout 3 curl -s -I "https://$domain" >/dev/null 2>&1; then
        echo "  ✅ $domain доступен"
    else
        echo "  ❌ $domain недоступен"
    fi
done
