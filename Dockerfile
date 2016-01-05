FROM jwilder/nginx-proxy

COPY nginx.tmpl /app/ 
COPY Procfile /app/

COPY nginx.conf /etc/nginx/nginx.conf

RUN rm /usr/share/nginx/html/index.html 
RUN rm -r /etc/nginx/conf.d

VOLUME /usr/share/nginx/html/
