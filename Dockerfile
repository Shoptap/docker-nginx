FROM nginx:1.9

COPY nginx.conf /etc/nginx/nginx.conf

RUN rm /usr/share/nginx/html/index.html 

CMD ["nginx"]
