#!/bin/bash

# UDP Cast Troubleshooting Script
# Helps diagnose issues with remote UDP receiver setup

set -euo pipefail

HOST="${1:-foundation13.ilt.example.com}"
SSH_TIMEOUT=30

echo "=== UDP Cast Troubleshooting for $HOST ==="
echo

echo "1. Testing SSH connectivity..."
if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "echo 'SSH OK'" 2>/dev/null; then
    echo "   ✓ SSH connectivity: OK"
else
    echo "   ✗ SSH connectivity: FAILED"
    exit 1
fi

echo
echo "2. Checking if udp-receiver is installed..."
if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "which udp-receiver" 2>/dev/null; then
    echo "   ✓ udp-receiver found"
else
    echo "   ✗ udp-receiver NOT FOUND"
    echo "   Please install udpcast package on $HOST"
    echo "   Try: sudo yum install udpcast  OR  sudo apt-get install udpcast"
    exit 1
fi

echo
echo "3. Checking udp-receiver version and options..."
ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "udp-receiver --help | head -5" 2>/dev/null || echo "   Could not get help info"

echo
echo "4. Checking network interface..."
if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "ip addr show br0" >/dev/null 2>&1; then
    echo "   ✓ br0 interface exists"
else
    echo "   ⚠ br0 interface not found, checking other interfaces:"
    ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "ip -br addr show | grep -v lo" 2>/dev/null || echo "   Could not list interfaces"
fi

echo
echo "5. Checking if ports 9000-9001 are available..."
for port in 9000 9001; do
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "netstat -ln | grep :$port" 2>/dev/null; then
        echo "   ⚠ Port $port appears to be in use"
    else
        echo "   ✓ Port $port available"
    fi
done

echo
echo "6. Testing basic udp-receiver command..."
echo "   Running: udp-receiver --help >/dev/null"
if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "udp-receiver --help >/dev/null 2>&1"; then
    echo "   ✓ udp-receiver command works"
else
    echo "   ✗ udp-receiver command failed"
fi

echo
echo "7. Testing file creation permissions..."
TEST_FILE="/tmp/udpcast-test-$$"
if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "touch $TEST_FILE && rm $TEST_FILE" 2>/dev/null; then
    echo "   ✓ Can create files in /tmp"
else
    echo "   ✗ Cannot create files in /tmp"
fi

echo
echo "8. Checking system resources..."
echo "   Memory usage:"
ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "free -h | grep -E 'Mem|Swap'" 2>/dev/null || echo "   Could not check memory"
echo "   Disk space in /tmp:"
ssh -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "df -h /tmp | tail -1" 2>/dev/null || echo "   Could not check disk space"

echo
echo "=== Troubleshooting complete ==="
