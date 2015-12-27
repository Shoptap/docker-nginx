FROM jwilder/nginx-proxy

COPY nginx.tmpl /app/ 
COPY Procfile /app/

RUN rm /usr/share/nginx/html/index.html 
RUN rm -r /etc/nginx/conf.d

VOLUME /usr/share/nginx/html/
