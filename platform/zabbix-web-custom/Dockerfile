FROM zabbix/zabbix-web-nginx-mysql:alpine-7.0.30

USER root

COPY ui/ /usr/share/zabbix/

RUN chown -R nginx:nginx /usr/share/zabbix
