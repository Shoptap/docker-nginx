FROM nginx:1.9
COPY nginx.conf /etc/nginx/nginx.conf.tmpl

RUN rm /etc/nginx/nginx.conf
RUN rm /usr/share/nginx/html/index.html 
ADD entrypoint.sh /usr/sbin
RUN chmod +5 /usr/sbin/entrypoint.sh

ENTRYPOINT ["entrypoint.sh"]

CMD ["nginx"]
