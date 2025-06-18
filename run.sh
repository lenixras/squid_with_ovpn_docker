#!/bin/bash

# Initialiser Squid (création des dossiers de cache)
echo "Initialisation de Squid..."
squid -z

# Démarrer OpenVPN
echo "Démarrage d'OpenVPN..."
mkdir -p /dev/net
mknod /dev/net/tun c 10 200
chmod 600 /dev/net/tun
cd /etc/openvpn/
openvpn --config client.ovpn --daemon
ip route add 192.168.60.0/23 via 172.22.0.1 dev eth0

# Attendre que la connexion soit établie
sleep 5

# Démarrer Squid en foreground
echo "Démarrage de Squid..."
squid -N -d 1
