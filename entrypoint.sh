#!/bin/bash
cp /etc/nginx/nginx.conf.tmpl /etc/nginx/nginx.conf
/bin/sed -i "s/gunicorn_server_placeholder/${WEB_1_PORT_3000_TCP_ADDR}/" /etc/nginx/nginx.conf
exec $@
