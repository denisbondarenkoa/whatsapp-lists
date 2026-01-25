#!/bin/bash
# Простой скрипт создания списков WhatsApp
set -e

echo "Создание списков WhatsApp..."
mkdir -p lists

# Домены
cat > lists/domains.txt << 'DOMAINS'
# WhatsApp domains
whatsapp.com
web.whatsapp.com
api.whatsapp.com
chat.whatsapp.com
call.whatsapp.com
beta.whatsapp.com
s.whatsapp.net
static.whatsapp.net
mmg.whatsapp.net
facebook.com
www.facebook.com
fbcdn.net
# Generated: $(date)
DOMAINS

# CIDR
cat > lists/cidr.txt << 'CIDR'
# Meta IP ranges
31.13.24.0/21
31.13.64.0/18
157.240.0.0/16
129.134.0.0/16
173.252.64.0/18
# Generated: $(date)
CIDR

echo "✅ Готово!"
echo "  Доменов: $(wc -l < lists/domains.txt)"
echo "  CIDR: $(wc -l < lists/cidr.txt)"
