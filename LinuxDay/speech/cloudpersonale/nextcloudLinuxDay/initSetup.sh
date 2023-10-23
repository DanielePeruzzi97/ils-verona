#!/bin/bash

#############################################
#                                           #
#  Script di installazione di nextcloud     #
#                                           #
#############################################

# Variabili di configurazione
#############################################
PHPVERSION=8.1
POSTGRES_VERSION=15
NEXTCLOUD_VERSION=27.0.2
NEXTCLOUD_ADMIN=admin
NEXTCLOUD_ADMIN_PASSWORD=admin
NEXTCLOUD_POSTGRES_DB=nextcloud
NEXTCLOUD_POSTGRES_USER=nextcloud
NEXTCLOUD_POSTGRES_PASSWORD=nextcloud
WEB_FOLDER=/usr/share/nginx/html
NEXTCLOUD_FOLDER=${WEB_FOLDER}/nextcloud
occ="sudo -u www-data php ${NEXTCLOUD_FOLDER}/occ"
DB_POSTGRES_HOST_IP=127.0.0.1
DB_POSTGRES_HOST_IP=5432
PROTOCOLWEB=http
REDIS_HOSTNAME=localhost
REDIS_PORT=6379
#############################################
function doMsg(){
    Green=$'\e[1;32m'
    White=$'\e[0m'
    msg=$1
    echo "${Green}" "${msg}" "${White}"
}

function installNginx(){
    doMsg "--> Installo nginx e nginx-estras"
    apt-get update -y
    doMsg "--> Installazione nginx"
    apt-get install nginx -y -qq
    apt-get install nginx-extras -y -qq
}

function startNginx(){
    case $1 in
        start)
            doMsg "--> Configurazione servizio systemd e avvio di Nginx"
            systemctl enable nginx
            systemctl start nginx
            ;;
        restart)
            doMsg "--> Riavvio di Nginx"
            systemctl restart nginx
            ;;
        stop)
            doMsg "--> Arresto di Nginx"
            systemctl stop nginx
            ;;
        *)
            doMsg "--> Parametro non valido"
            exit 1
            ;;
    esac
}

function installPostgres(){
    dsh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/pgdg.asc &>/dev/null
    apt-get update

    doMsg "--> Installo postgresql ${POSTGRES_VERSION}"
    apt-get install postgresql-${POSTGRES_VERSION} postgresql-client-${POSTGRES_VERSION} -y

    doMsg "--> Avvio postgresql ${POSTGRES_VERSION}"
    systemctl start postgresql
}

function configureDatabase(){
    doMsg "--> Configuro il database"
    sudo -u postgres psql <<END
    CREATE USER ${NEXTCLOUD_POSTGRES_USER} WITH PASSWORD '${NEXTCLOUD_POSTGRES_PASSWORD}';
    CREATE DATABASE ${NEXTCLOUD_POSTGRES_DB} TEMPLATE template0 ENCODING 'UNICODE';
    ALTER DATABASE ${NEXTCLOUD_POSTGRES_DB} OWNER TO ${NEXTCLOUD_POSTGRES_USER};
    GRANT ALL PRIVILEGES ON DATABASE ${NEXTCLOUD_POSTGRES_DB} TO ${NEXTCLOUD_POSTGRES_USER};
    GRANT CREATE ON SCHEMA public to ${NEXTCLOUD_POSTGRES_USER};
END
}

function installRedis(){
    doMsg "--> Installo redis"
    REDISCONFIGFILE=/etc/redis/redis.conf
    apt-get install redis-server -y -qq
    sed '/#ADDCUSTOM/,$d' ${REDISCONFIGFILE} > ${REDISCONFIGFILE}.new
    mv ${REDISCONFIGFILE} ${REDISCONFIGFILE}.old
    mv ${REDISCONFIGFILE}.new ${REDISCONFIGFILE}
    echo "#ADDCUSTOM" >> ${REDISCONFIGFILE}
    echo "bind 127.0.0.1 ::1" >> ${REDISCONFIGFILE}
    systemctl restart redis
}

function installDep(){
    doMsg "--> Installo le dipendenze"
    apt-get install curl gnupg2 gnupg openssl ca-certificates lsb-release ubuntu-keyring unzip -y -qq
    apt-get install php${PHPVERSION} php${PHPVERSION}-fpm php${PHPVERSION}-gd php${PHPVERSION}-pgsql php${PHPVERSION}-curl \
        php${PHPVERSION}-mbstring php${PHPVERSION}-intl php-apcu \
        php${PHPVERSION}-gmp php${PHPVERSION}-bcmath php-imagick php${PHPVERSION}-xml php-redis php${PHPVERSION}-zip unzip libmagickcore-6.q16-3-extra \
        php${PHPVERSION}-memcached php${PHPVERSION}-memcache -y -qq
}

function downloadNC(){
    wget -O nextcloud-${NEXTCLOUD_VERSION}.zip https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip
    md5sum nextcloud-${NEXTCLOUD_VERSION}.zip > nextcloud.md5
}

function getNC(){
    doMsg "--> Scarico la versione di nextcloud ${NEXTCLOUD_VERSION}"
    cd $WEB_FOLDER
    if [ ! -f nextcloud.md5 ]; then
        downloadNC
    else
        md5sum -c nextcloud.md5
        if [ ! $? -eq 0 ]; then
            doMsg "--> Pacchetto ${NEXTCLOUD_VERSION} già presente ma checksum cambiato, lo riscarico"
            downloadNC
        else
            doMsg "--> Il pacchetto ${NEXTCLOUD_VERSION} è già presente, non lo scarico"
        fi
    fi
    cd $WEB_FOLDER/
    unzip -q -o nextcloud-${NEXTCLOUD_VERSION}.zip
}


function configureNginx(){
    sed -i 's/user  nginx;/user  www-data;/' /etc/nginx/nginx.conf
    cp /osa/app/nextcloud.conf /etc/nginx/conf.d/
    if [ -f /etc/nginx/conf.d/default.conf ]; then
        mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
    fi
    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm /etc/nginx/sites-enabled/default
    fi
}

function configureNextcloud(){
    doMsg "--> Controlla permessi cartella di setup"
    chown -R www-data:www-data ${NEXTCLOUD_FOLDER}

    doMsg "--> Installo Nextcloud"
    $occ maintenance:install --database \
    "pgsql" --database-name "${NEXTCLOUD_POSTGRES_DB}"  --database-user "${NEXTCLOUD_POSTGRES_USER}" --database-pass \
    "${NEXTCLOUD_POSTGRES_PASSWORD}" --database-host ${DB_POSTGRES_HOST_IP} --database-port ${DB_POSTGRES_PORT} --admin-user \
    "${NEXTCLOUD_ADMIN}" --admin-pass "${NEXTCLOUD_ADMIN_PASSWORD}" --data-dir "/nfs4/www/data"

    
    chmod +x ${NEXTCLOUD_FOLDER}/occ
    $occ config:system:set overwriteprotocol --value "${PROTOCOLWEB}"
    #pulisce dal cestino gli oggetti più vecchi di 30 giorni e quando serve spazio
    $occ config:system:set trashbin_retention_obligation --value '30,auto'
    #Tiene le versioni dei file per 365 giorni, poi le imposta in stato expired e le tiene per altri 30 giorni
    $occ config:system:set versions_retention_obligation --value '365,30'
    $occ config:system:set htaccess.RewriteBase --value /
    $occ maintenance:update:htaccess #enabled pretty urls
    $occ config:system:set filelocking.enabled  --value=true
    $occ config:system:set redis host --value="${REDIS_HOSTNAME}"
    $occ config:system:set redis port --value="${REDIS_PORT}" --type=integer
    $occ config:system:set 'memcache.local' --value='\OC\Memcache\APCu'
    $occ config:system:set 'memcache.distributed' --value='\OC\Memcache\Redis'
    $occ config:system:set 'memcache.locking' --value='\OC\Memcache\Redis'

    #ogni altra configurazione utile è qui https://docs.nextcloud.com/server/19/admin_manual/configuration_server/config_sample_php_parameters.html?highlight=overwrite%20cli%20url
    chown -R www-data:www-data ${NEXTCLOUD_FOLDER}/config
    chmod -R 755 ${NEXTCLOUD_FOLDER}/config
    chmod 650 ${NEXTCLOUD_FOLDER}/config/*
}

function configureNginxCache(){
    doMsg "--> Configurazione delle ottimizzazioni per la cache"

    chmod -R 755 $NEXTCLOUD_FOLDER/config

    export php_max_time=3600
    export php_memory_limit=512M
    export php_upload_limit=10G

    cli_destination="/etc/php/${PHPVERSION}/cli/php.ini"
    php_fpm_file="/etc/php/${PHPVERSION}/fpm/php.ini"
    www_fpm_config="/etc/php/${PHPVERSION}/fpm/pool.d/www.conf"
    if [ ! -f "${cli_destination}.back" ]; then
        cp -f "${cli_destination}" "${cli_destination}.back"
    else
        cp -f "${cli_destination}.back" "${cli_destination}"
    fi
    if [ ! -f "${php_fpm_file}.back" ]; then
        cp -f "${php_fpm_file}" "${php_fpm_file}.back"
    else
        cp -f "${php_fpm_file}.back" "${php_fpm_file}"
    fi
    if [ ! -f "${www_fpm_config}.back" ]; then
        cp -f "${www_fpm_config}" "${www_fpm_config}.back"
    else
        cp -f "${www_fpm_config}.back" "${www_fpm_config}" 
    fi
    
    cd $NEXTCLOUD_FOLDER

    sed -i -e "s/memory_limit\s*=.*/memory_limit = ${php_memory_limit}/g" \
        -e "s/upload_max_filesize\s*=.*/upload_max_filesize = ${php_upload_limit}/g" \
        -e "s/post_max_size\s*=.*/post_max_size = ${php_upload_limit}/g" \
        -e "s/Max_execution_time\s*=.*/max_execution_time = ${php_max_time}/g" \
        -e "s/max_input_time\s*=.*/max_input_time = ${php_max_time}/g" \
        -e "s/;?opcache\.save_comments=[^=]*/opcache.save_comments=1/" \
        -e "s/;?opcache\.revalidate_freq=[^=]*/opcache.revalidate_freq=60/" \
        -e "s/;?opcache\.memory_consumption=[^=]*/opcache.memory_consumption=64/" \
        -e "s/;?opcache\.interned_strings_buffer=[^=]*/opcache.interned_strings_buffer=32/" \
    "${cli_destination}"

    sed -i -e "s/memory_limit\s*=.*/memory_limit = ${php_memory_limit}/g" \
        -e "s/upload_max_filesize\s*=.*/upload_max_filesize = ${php_upload_limit}/g" \
        -e "s/post_max_size\s*=.*/post_max_size = ${php_upload_limit}/g" \
        -e "s/Max_execution_time\s*=.*/max_execution_time = ${php_max_time}/g" \
        -e "s/max_input_time\s*=.*/max_input_time = ${php_max_time}/g" \
        -e "s/;?opcache\.save_comments=[^=]*/opcache.save_comments=1/" \
        -e "s/;?opcache\.revalidate_freq=[^=]*/opcache.revalidate_freq=60/" \
        -e "s/;?opcache\.memory_consumption=[^=]*/opcache.memory_consumption=64/" \
        -e "s/;?opcache\.interned_strings_buffer=[^=]*/opcache.interned_strings_buffer=32/" \
    "${php_fpm_file}"

    sed -i -e '/clear_env/ s/^.//' ${www_fpm_config}
    sed -i -e '/env\[/ s/^.//'  ${www_fpm_config}

    echo apc.enable_cli=1 >> "${cli_destination}" 

    doMsg "--> Applico le modifiche php"
    systemctl restart php${PHPVERSION}-fpm
    systemctl restart nginx
}


function customizingNextcloud(){
    doMsg "--> Configurazione di personalizzazioni utente"
    $occ config:system:set default_phone_region --value=IT
    $occ config:system:set default_phone_region --value IT
    $occ config:system:set default_locale --value it_IT
    $occ config:system:set enforce_locale --value it_IT
    $occ config:system:set default_language --value it
    $occ config:system:set enforce_language --value it
    $occ config:system:set skeletondirectory --value ""
}


installNginx
startNginx start
installDep
startNginx restart
installPostgres
configureDatabase
installRedis
configureNginx
configureNginxCache
getNC
configureNextcloud
#customizingNextcloud