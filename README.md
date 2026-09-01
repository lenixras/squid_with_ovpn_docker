# squid_with_ovpn_docker

Proxy **Squid** (port 3128) dockerisé sortant par un tunnel **OpenVPN**.
Whitelist de domaines + ACL IP — usage ciblé (vérif IP, accès géo-restreint),
pas un proxy d'usage général.

```
  client → Squid (3128) → tun0 → eth0 → VPN provider → Internet
```

## Démarrage

```bash
# Fichiers à fournir localement (gitignored) :
#   openvpn/client.ovpn  : config OpenVPN de ton provider
#   openvpn/proxy-auth.txt : user/pass provider (ligne 1 / ligne 2)

docker compose up -d --build
docker exec squid-openvpn-proxy ip addr show tun0   # tunnel OK ?
curl -x http://USER:PASS@host:3128 https://api.myip.com
```

## Fichiers

| Fichier                    | Rôle                                                                 |
| -------------------------- | -------------------------------------------------------------------- |
| `Dockerfile`               | Debian + Squid + OpenVPN + iproute2                                  |
| `docker-compose.yml`       | Bind :3128, `NET_ADMIN`, mappage `/dev/net/tun`                     |
| `run.sh`                   | `squid -z` → `mknod tun` → `openvpn --daemon` → route statique → `squid -N` |
| `config/squid.conf`        | ACL IP (`192.168.60.253`, `192.168.61.4`) + whitelist `.myip.com`, `.iqos.com` |
| `openvpn/{client.ovpn,client.key,client.crt,ca.crt,proxy-auth.txt}` | **gitignored**, à fournir localement |
| `logs/`                    | Logs Squid (gitignored)                                              |

Adapter dans `run.sh` la ligne `ip route add 192.168.60.0/23 via 172.22.0.1`
au LAN derrière le VPN et à la gateway Docker.

## Commandes

```bash
docker exec squid-openvpn-proxy tail -f /var/log/squid/access.log
docker exec squid-openvpn-proxy squid -k reconfigure   # reload squid.conf
docker exec squid-openvpn-proxy cat /var/log/openvpn-status.log
```

## Sécurité

- Aucun secret commité. Les fichiers `openvpn/*` sont dans `.gitignore`.
- Whitelist stricte (`acl allowlink`) + ACL IP côté Squid : seules 2 IP sources,
  2 domaines dest.
- `NET_ADMIN` + `/dev/net/tun` = privilèges minimum pour le tunnel.

## Limites

- ACL par IP, pas par user → multi-user = `auth_param basic` + `htpasswd`.
- Pas de protection DNS leak explicite : vérifier `dhcp-option DNS` dans
  `client.ovpn` (sinon DNS fuit hors tunnel).
- CONNECT forwarding (pas MITM) : Squid ne voit le SNI qu'en clair.

## Licence

MIT — voir [`LICENSE`](LICENSE).