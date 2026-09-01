# squid_with_ovpn_docker

Conteneur Docker encapsulant un proxy **Squid** (port 3128) qui sort sur Internet
au travers d'un tunnel **OpenVPN**. Toutes les requêtes du proxy passent donc
par le VPN, ce qui masque l'IP réelle du client final.

Le proxy n'est **pas ouvert** : authentification basique + ACL IP + whitelist de
domaines (utilisation type "vérifier mon IP publique" / "accéder à un service
géo-restreint", pas un proxy d'usage général).

## Architecture

```
  client (browser, curl...)
        │
        │ HTTP proxy, auth basique
        ▼
  ┌─────────────────────────────┐
  │ container squid-openvpn-proxy│
  │                             │
  │  Squid  ──►  tun0  ──►  eth0│
  │   :3128        ▲             │
  │                │             │
  │            OpenVPN client    │
  └─────────────────────────────┘
                                 │
                                 ▼
                            VPN provider
                                 │
                                 ▼
                              Internet
```

## Stack

- Debian (image `debian:latest`)
- Squid 5.x (cache disque UFS 100 Mo)
- OpenVPN 2.x
- iptables / iproute2 (pour la route statique vers le LAN derrière le VPN)

## Arborescence

```
.
├── Dockerfile
├── docker-compose.yml
├── run.sh                 # init Squid, monte /dev/net/tun, lance openvpn, route, squid
├── config/
│   └── squid.conf         # ACL, whitelist, auth basique
├── openvpn/               # ⚠ fichiers sensibles — voir openvpn/README
│   └── README             # instructions pour client.ovpn + proxy-auth.txt
└── logs/                  # logs Squid persistés (volume, gitignored)
```

Les fichiers OpenVPN réels (`client.ovpn`, `client.key`, `client.crt`, `ca.crt`,
`proxy-auth.txt`) ne sont **pas** dans ce repo : ils sont listés dans
`.gitignore` et doivent être fournis localement au déploiement. Voir
[`openvpn/README`](openvpn/README).

## Démarrage

```bash
# 1. Créer openvpn/client.ovpn avec ta config provider VPN (voir openvpn/README)
# 2. Créer openvpn/proxy-auth.txt (user ligne 1, password ligne 2)
# 3. Éditer config/squid.conf si tes ACL IP changent

docker compose up -d --build

# Vérifier que le tunnel est monté
docker exec squid-openvpn-proxy ip addr show tun0

# Tester le proxy
curl -x http://USER:PASSWORD@squid-host:3128 https://api.myip.com
```

## Configuration

### `openvpn/client.ovpn`

Fichier de configuration standard OpenVPN. Doit contenir au minimum :

```ovpn
client
dev tun
proto udp
remote vpn.example.com 1194
resolv-retry infinite
nobind

ca   ca.crt
cert client.crt
key  client.key

auth-user-pass proxy-auth.txt   # credentials provider VPN (⚠ NE PAS commit)
```

### `openvpn/proxy-auth.txt`

Deux fichiers à ne pas confondre :

- `openvpn/proxy-auth.txt` = credentials du **provider VPN** (lus par OpenVPN).
- Les credentials **Squid** (auth basique du proxy) se gèrent dans
  `squid.conf` via `htpasswd` (non détaillé ici, dépend de ton htpasswd_file).

### `config/squid.conf`

Points clés :

```conf
http_port 3128

acl localnet src all
acl ipadmin src 192.168.60.253
acl ipadmin src 192.168.61.4

acl allowlink dstdomain .myip.com .iqos.com

http_access allow ipadmin        # seuls ces 2 IP peuvent se connecter au proxy
http_access deny all

http_access allow allowlink       # seules ces destinations sont forwardées
http_access deny all
```

Pour autoriser d'autres domaines : ajouter à `acl allowlink`.

### `run.sh`

Script d'init lancé par le `CMD` du `Dockerfile`. Il fait tout, dans l'ordre :

```bash
#!/bin/bash
set -e

echo "Initialisation de Squid..."
squid -z          # crée les dossiers de cache UFS (/var/cache/squid/00..FF)
                   # idempotent : ne fait rien s'ils existent déjà

echo "Démarrage d'OpenVPN..."
mkdir -p /dev/net
mknod /dev/net/tun c 10 200    # crée le device TUN s'il n'existe pas
chmod 600 /dev/net/tun          # seul root peut l'utiliser

cd /etc/openvpn/
openvpn --config client.ovpn --daemon    # lance openvpn en background,
                                          # logs → /var/log/openvpn-status.log
ip route add 192.168.60.0/23 via 172.22.0.1 dev eth0
                                          # route statique vers le LAN derrière
                                          # le VPN (adapte à TON réseau)

sleep 5        # laisse openvpn finir de monter le tunnel avant squid

echo "Démarrage de Squid..."
squid -N -d 1  # -N = foreground (requis par Docker, sinon le container exit)
                # -d 1 = debug verbeux, à baisser (0) en prod
```

**Pièges & points d'attention :**

- `mknod /dev/net/tun` : sur l'hôte, `devices: /dev/net/tun:/dev/net/tun`
  dans `docker-compose.yml` est censé suffire, mais ce `mknod` couvre le cas
  où le mappage ne s'est pas fait (image de base Debian générique).
- `ip route add` : pas de `--` pour éviter un échec silencieux, mais
  l'ajout est **idempotent seulement via `ip route replace`** sinon deux
  démarrages successifs du container → erreur. À patcher si tu rebuilds
  souvent.
- `sleep 5` : arbitraire. Si openvpn met >5s à monter (DNS lent, TLS
  handshake), Squid démarre avec tun0 non prêt → erreurs dans
  `/var/log/squid/cache.log`. Pour un démarrage robuste, remplacer par :
  ```bash
  until ip link show tun0 >/dev/null 2>&1; do sleep 1; done
  ```
- `squid -d 1` : niveau de debug 1 = bavard (logs plein). En prod baisser
  à `-d 0` ou retirer l'option (default 0).
- Le script **n'a pas de signal handler** : `docker compose restart` envoie
  SIGTERM → openvpn et squid meurent sans cleanup, le tunnel peut rester
  en état demi-mort côté provider. À améliorer avec un trap :
  ```bash
  trap 'kill $(cat /var/run/openvpn.pid 2>/dev/null) 2>/dev/null; squid -k shutdown' TERM INT
  ```

Pour autoriser d'autres domaines : ajouter à `acl allowlink`.

## Commandes utiles

```bash
# Logs Squid en direct
docker exec -it squid-openvpn-proxy tail -f /var/log/squid/access.log

# Vérifier IP vue depuis le container (doit être l'IP du VPN)
docker exec squid-openvpn-proxy curl https://api.myip.com

# Recharger Squid après modif de squid.conf
docker exec squid-openvpn-proxy squid -k reconfigure

# Vérifier que le tunnel est actif
docker exec squid-openvpn-proxy cat /var/log/openvpn-status.log

# Redémarrer proprement (couper openvpn puis squid)
docker compose restart
```

## Sécurité

- **Aucun secret n'est commité** dans ce repo. Les fichiers sensibles
  (`client.ovpn`, `client.key`, `client.crt`, `ca.crt`, `proxy-auth.txt`) sont
  listés dans `.gitignore` et doivent être fournis localement au déploiement.
- `cap_add: NET_ADMIN` + `devices: /dev/net/tun` sont nécessaires au tunnel.
  Ce sont les seuls privilèges accordés.
- L'ACL Squid n'autorise que 2 IP sources → réduit la surface d'exposition
  même si le container est exposé.

## Limites connues

- **Un seul client à la fois côté IP** : Squid bind sur 0.0.0.0 mais ACL par IP,
  pas par user. Pour du multi-user propre, basculer sur `auth_param basic`
  + `htpasswd`.
- **Pas de DNS leak protection explicite** : si `client.ovpn` ne force pas le
  DNS via le tunnel, les requêtes DNS fuient en clair. Vérifier
  `dhcp-option DNS` dans le `.ovpn` et ajouter `dns_via_dhcp` ou forcer
  Squid à resolver via le tunnel.
- **Pas de HTTPS interception / SNI filtering** : le proxy est en CONNECT
  forwarding, pas en MITM. La whitelist `dstdomain` est appliquée mais Squid
  ne verra le SNI qu'en clair, ce qui est OK ici (peu de domaines).

## Licence

MIT — voir le fichier [`LICENSE`](LICENSE).
