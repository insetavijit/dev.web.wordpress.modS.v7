FROM php:8.2-apache

# Install system dependencies
RUN apt-get update && apt-get install -y \
    zip unzip git mariadb-client less curl \
    && docker-php-ext-install mysqli pdo pdo_mysql \
    && rm -rf /var/lib/apt/lists/*

# Enable Apache mod_rewrite
RUN a2enmod rewrite \
    && echo "ServerName localhost" >> /etc/apache2/apache2.conf

# Install Xdebug
RUN pecl install xdebug \
    && docker-php-ext-enable xdebug

# Copy custom php.ini
COPY ./php.ini /usr/local/etc/php/conf.d/php.ini

# Install WP-CLI
RUN curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp \
    && wp --info

# Copy init script
COPY ./init-wordpress.sh /usr/local/bin/init-wordpress.sh
RUN chmod +x /usr/local/bin/init-wordpress.sh

# Run init script on container start
# ENTRYPOINT ["bash", "/usr/local/bin/init-wordpress.sh"]
