# Utiliser l'image Debian la plus récente
FROM debian:latest

# Mettre à jour et installer les paquets nécessaires
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y squid openvpn vim iptables procps iproute2 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Créer les dossiers nécessaires pour Squid
RUN mkdir -p /var/log/squid /var/cache/squid && \
    chown -R proxy:proxy /var/log/squid /var/cache/squid

# Copier les fichiers de configuration
COPY config/squid.conf /etc/squid/squid.conf
COPY openvpn/ /etc/openvpn/
COPY run.sh /run.sh

# Rendre le script exécutable
RUN chmod +x /run.sh

# Exposer le port du proxy
EXPOSE 3128

# Démarrer le script d'initialisation
CMD ["/run.sh"]
