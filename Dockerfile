FROM nginx:1.9.9
MAINTAINER Richard Adams richard@madwire.co.uk

# Install wget and install/updates certificates
RUN apt-get update \
 && apt-get install -y -q --no-install-recommends \
    ca-certificates \
    wget \
    build-essential \
    openssl \
    libssl-dev \
    ruby-full \
 && apt-get clean \
 && rm -r /var/lib/apt/lists/*

# Configure Nginx and apply fix for very long server names
RUN echo "daemon off;" >> /etc/nginx/nginx.conf \
 && sed -i 's/^http {/&\n    server_names_hash_bucket_size 128;/g' /etc/nginx/nginx.conf

# Install Forego
RUN wget -P /usr/local/bin https://godist.herokuapp.com/projects/ddollar/forego/releases/current/linux-amd64/forego \
 && chmod u+x /usr/local/bin/forego

# Install App dependancies
RUN gem install faye-websocket --no-ri --no-rdoc && gem install tutum --no-ri --no-rdoc

ENV NGINX_DEFAULT_CONF=/etc/nginx/nginx.conf

COPY nginx.conf /etc/nginx/nginx.conf

COPY Procfile /app/
COPY tutum.rb /app/ 
COPY nginx.conf.erb /app/
WORKDIR /app/

RUN rm /usr/share/nginx/html/index.html 
RUN rm -r /etc/nginx/conf.d

CMD ["forego", "start", "-r"]
