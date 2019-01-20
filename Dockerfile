# Create ASSP Docker Container
FROM alpine:3.8

ENV TZ=America/New_York
ENV MY_NAME=mail.yourdomain.com
ENV MAILADMIN=youremail@addresshere.com
ENV ASSP_PASS=YOUR-ASSP-PASSWORD-HERE
ENV SMTP_DESTINATION=mail.YOURMAILSMTPSERVER.com:25
ENV SMTP_DESTINATION_SSL=mail.YOURMAILSMTPSERVER.com:465
ENV ACCEPT_ALL_MAIL=your.ip.here|partial.ip.here
ENV RELAY_HOST=127.0.0.1:1025
ENV RELAY_PORT=2025
ENV ALLOW_RELAY_CON=your.ip.here|partial.ip.here
ENV DEFAULT_LOCALHOST=yourdomain.com
ENV SEND_HAM_INBOUND=ham.j2bgtj41o@yourdomain.com
ENV SEND_HAM_OUTBOUND=ham.j2bgtj41o@yourdomain.com
ENV POSTMASTER=postmaster@yourdomain.com
ENV LOCAL_DOMAINS=yourdomain.com|yourseconddomain.org
ENV MY_SERVER_RE=your.external.ip|your.internal.ip|mail.yourdomain.com
ENV NO_DELAY=@netflix.com

# Set the Alpine APK Repositories to use
RUN echo $'@edge http://nl.alpinelinux.org/alpine/edge/main\n@testing http://nl.alpinelinux.org/alpine/edge/testing' >> /etc/apk/repositories
# Set the Timezone of the image to be built
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
# Ensure we have the latest packages available from the APK REPO
RUN apk update && apk upgrade && apk --no-cache add ca-certificates tzdata bash supervisor make automake \
    gcc zip unzip unrar openrc sudo libc-dev openssl openssl-dev db-dev yaml gnupg linux-headers mlocate \
    dnssec-root perl perl-sys-hostname-long perl-net-dns perl-lwp-protocol-https perl-dev yaml perl-yaml \
    rsyslog curl perl-io-compress perl-dbd-mysql perl-dbd-odbc perl-xml-rss perl-encode perl-file-temp \
    perl-pod-coverage perl-test-deep perl-mail-spf g++ p7zip busybox-extras

# Install CPAN modules
RUN curl -L https://cpanmin.us | perl - App::cpanminus && cpan App::cpanoutdated && (cpan-outdated -p | cpanm || true) && \
    cpanm CPAN Log::Log4perl inc::latest Bundle::CPAN

# Install MariaDB
RUN apk add --update mariadb mariadb-server-utils mariadb-doc mariadb-openrc mariadb-client && \
    { \
    echo '#!/bin/bash'; \
    echo 'touch /tmp/init; [[ ! -f /etc/mysql/my.cnf ]] && (cp /usr/share/mariadb/my-small.cnf /etc/mysql/my.cnf && chown mysql:mysql /etc/mysql/my.cnf)'; \
    echo '[[ ! -d /run/mysqld ]] && (mkdir -p /run/mysqld && chown -R mysql:mysql /run/mysqld)'; \
    echo "[[ -n \"${SKIP_INNODB}\" ]] || [[ -f \"/var/lib/mysql/noinnodb\" ]] && sed -i -e '/\[mysqld\]/a skip-innodb\ndefault-storage-engine=MyISAM\ndefault-tmp-storage-engine=MyISAM' -e '/^innodb/d' /etc/mysql/my.cnf"; \
    echo "if [ -z \"\$(ls -A /var/lib/mysql/)\" ]; then ROOTPW=\"''\""; \
    echo "  [[ -n \"${SKIP_INNODB}\" ]] && touch /var/lib/mysql/noinnodb; [[ -n \"${MYSQL_ROOT_PASSWORD}\" ]] && ROOTPW=\"PASSWORD('${MYSQL_ROOT_PASSWORD}')\""; \
    echo "  echo \"INSERT INTO user VALUES ('%','root',${ROOTPW},'Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','Y','','','','',0,0,0,0,'','','N', 'N','', 0);\" > /usr/share/mariadb/mysql_system_tables_data.sql"; \
    echo "  mysql_install_db --rpm  --user=mysql --cross-bootstrap; [[ -n \"${MYSQL_USER_DB}\" ]] && echo \"create database if not exists ${MYSQL_USER_DB} character set utf8 collate utf8_general_ci; \" >> /tmp/init"; \
    echo "  echo \"grant all on ${MYSQL_USER_DB}.* to '${MYSQL_USER}'@'%' identified by '${MYSQL_USER_PASSWORD}'; \" >> /tmp/init"; \
    echo '  echo "flush privileges;" >> /tmp/init'; \
    echo 'fi; /usr/bin/mysqld --skip-name-resolve --user=mysql --debug-gdb --init-file=/tmp/init'; \
    } | tee /start_mysqld.sh

# Install ClamAV
RUN apk add --update clamav clamav-daemon && mkdir /run/clamav && chown clamav /run/clamav && \
    printf '#!/bin/bash\n[[ -d /var/log/clamav ]] || (mkdir /var/log/clamav && chown clamav /var/log/clamav)\n\
/usr/bin/freshclam -v' > /freshclam-daily.sh && chmod a+x /freshclam-daily.sh && \
    printf '#!/bin/bash\n[[ -d /var/log/clamav ]] || mkdir /var/log/clamav\n\
chown clamav /var/log/clamav && /usr/sbin/clamd -c /etc/clamav/clamd.conf &' > /start_clamd.sh && \
    /bin/bash /start_clamd.sh && freshclam -v && \
    (cpan File::Scan::ClamAV || true) && cd /root/.cpan/build/File-Scan-ClamAV-1.95-0 && \
    make install && ln -s /freshclam-daily.sh /etc/periodic/daily/freshclam

# Install Postfix & Assign Port 1025
RUN apk add --update postfix && postconf -e smtputf8_enable=no; postalias /etc/postfix/aliases; postconf -e mydestination=; \
    postconf -e relay_domains=; postconf -e smtpd_delay_reject=yes; postconf -e smtpd_helo_required=yes; \
    postconf -e "smtpd_helo_restrictions=permit_mynetworks,reject_invalid_helo_hostname,permit"; \
    postconf -e "mynetworks=127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"; \
    sed -i -r -e 's/smtp      inet  n       -       n       -       -       smtpd/1025      inet  n       -       n       -       -       smtpd/' /etc/postfix/master.cf; \
    chown root /var/spool/postfix && chown root /var/spool/postfix/pid && \
    printf '#!/bin/bash\n/usr/sbin/postfix -c /etc/postfix start' > start_postfix.sh

# Install OpenDKIM
RUN apk add --update opendkim opendkim-utils && cp /etc/opendkim/opendkim.conf /etc/ && \
    printf '#!/bin/bash\n\
[[ -d /etc/opendkim/TrustedHosts ]] || mkdir /etc/opendkim/TrustedHosts\n\
[[ -d /etc/opendkim/KeyTable ]] || mkdir /etc/opendkim/KeyTable\n\
[[ -d /etc/opendkim/SigningTable ]] || mkdir /etc/opendkim/SigningTable\n\
[[ ! -f /etc/opendkim/opendkim.conf ]] && cp /etc/opendkim.conf /etc/opendkim/opendkim.conf\n\
chown opendkim /etc/opendkim -R\n\
sudo -u opendkim /usr/sbin/opendkim -p inet:8891 -x /etc/opendkim/opendkim.conf' > /start_opendkim.sh && \
  mkdir /run/opendkim && chown opendkim /run/opendkim && \
  printf 'Canonicalization        relaxed/simple\n\
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts\n\
InternalHosts           refile:/etc/opendkim/TrustedHosts\n\
KeyTable                refile:/etc/opendkim/KeyTable\n\
SigningTable            refile:/etc/opendkim/SigningTable' >> /etc/opendkim.conf

# Get & Install ASSP, filecommander, and libs
RUN cd /usr/share && wget --no-check-certificate https://sourceforge.net/projects/assp/files/latest/download?source=files -O ASSP.zip && unzip ASSP.zip && \
    mv assp/assp.cfg.rename_on_new_install assp/assp.cfg && cd /usr/share/assp && touch /usr/share/assp/assp.cfg.setdefaults && \
    addgroup assp && adduser -D assp -G assp assp && \
    wget https://sourceforge.net/projects/assp/files/ASSP%20V2%20multithreading/ASSP%20V2%20module%20installation/assp.mod.zip/download -O assp.mod.zip && \
    unzip assp.mod.zip && cd assp.mod/install && sed -i 's|/OpenSSL|/LibreSSL|g' mod_inst.pl && \
    cd /usr/share/assp && \
    wget --no-check-certificate https://sourceforge.net/projects/assp/files/ASSP%20V2%20multithreading/filecommander/1.05.ZIP/download -O filecommander-1.05.zip && \
    unzip filecommander-1.05.zip && yes | mv 1.05/images/* /usr/share/assp/images && yes | mv 1.05/lib/* /usr/share/assp/lib && \
    cd /usr/share/assp && \
    wget --no-check-certificate https://sourceforge.net/projects/assp/files/ASSP%20V2%20multithreading/lib/lib.zip/download -O assp-lib.zip && \
    (yes | unzip assp-lib.zip) && chown assp:assp /usr/share/assp -R && chmod +x /usr/share/assp/assp.pl && \
    printf '#!/bin/bash \n\
if [ -z $(ls -A /usr/share/assp) ]; then \n\
  cp -rp /usr/share/assp-orig/* /usr/share/assp \n\
fi \ncd /usr/share/assp && chown assp:assp /usr/share/assp -R && /usr/share/assp/assp.pl' >> /start_assp.sh
RUN cpanm -n Mail::SPF::Query Encode::Detect Schedule::Cron Sys::CpuAffinity
RUN printf 'your@address.here.com\nyouraddress@here.com' > /usr/share/assp/files/localuser.txt && \
    chown assp:assp /usr/share/assp/files/localuser.txt && chmod 755 /usr/share/assp/files/localuser.txt
RUN cd /usr/share/assp/assp.mod/install && perl mod_inst.pl && (cpan-outdated -p | cpanm || true)
RUN mv /usr/share/assp /usr/share/assp-orig && mkdir /usr/share/assp && chown assp:assp /usr/share/assp
RUN printf '#!/bin/bash \n\
if [ ! -f /usr/share/assp/assp.cfg.setdefaults ]; then exit 0; fi \n\
sleep 60; \n\
rm -rf /usr/share/assp/assp.cfg.setdefaults \n' > /assp-setdefaults.sh
    
# Create beginning of supervisord.conf file
RUN printf '[supervisord]\nnodaemon=true\nuser=root\nlogfile=/var/log/supervisord\n' > /etc/supervisord.conf && \
    printf '#!/bin/bash\n/usr/bin/supervisord -c /etc/supervisord.conf' > /start_supervisor.sh && \
# Create script to add more supervisor boot-time entries
    printf '#!/bin/bash \necho "[program:$1]";\necho "process_name  = $1";\n\
echo "autostart     = true";\necho "autorestart   = false";\necho "directory     = /";\n\
echo "command       = $2";\necho "startsecs     = 3";\necho "priority      = 1";\n\n' > /gen_sup.sh && \    
    chmod a+x /*.sh && \
    
RUN printf '#!/bin/bash\necho "sed -i \'s|$1|$2|g\' /usr/share/assp/assp.cfg"' > /assp_cfg.sh && \
    /assp_cfg.sh 'runAsUser:=' "runAsUser:=assp" >> /custom.cfg && \
    /assp_cfg.sh 'runAsGroup:=' "runAsGroup:=assp" >> /custom.cfg && \
    /assp_cfg.sh 'myhost:=' "myhost:=127.0.0.1" >> /custom.cfg && \
    /assp_cfg.sh 'mydb:=' "mydb:=assp" >> /custom.cfg && \
    /assp_cfg.sh 'myuser:=' "myuser:=assp" >> /custom.cfg && \
    /assp_cfg.sh 'mypassword:=' "mypassword:=${ASSP_PASS}" >> /custom.cfg && \
    /assp_cfg.sh 'whitelistdb:=database/whitelist' "whitelistdb:=DB:" >> /custom.cfg && \
    /assp_cfg.sh 'delaydb:=database/delaydb' "delaydb:=DB:" >> /custom.cfg && \
    /assp_cfg.sh 'redlist:=database/redlist' "redlist:=DB:" >> /custom.cfg && \
    /assp_cfg.sh 'spamdb:=database/spamdb' "spamdb:=DB:" >> /custom.cfg && \
    /assp_cfg.sh 'ldaplistdb:=database/ldaplist' "ldaplistdb:=DB:" >> /custom.cfg && \
    /assp_cfg.sh 'adminusersdb:=' "adminusersdb:=DB:" >> /custom.cfg && \
    /assp_cfg.sh 'persblackdb:=database/persblack' "persblackdb:=DB:" >> /custom.cfg && \
    /assp_cfg.sh 'pbdb:=database/pb/pbdb' "pbdb:=DB:" >> /custom.cfg && \
    /assp_cfg.sh 'smtpDestination:=125' "smtpDestination:=${SMTP_DESTINATION}" >> /custom.cfg && \
    /assp_cfg.sh 'listenPortSSL:=' "listenPortSSL:=465" >> /custom.cfg && \
    /assp_cfg.sh 'smtpDestinationSSL:=' "smtpDestinationSSL:=${SMTP_DESTINATION_SSL}" >> /custom.cfg && \
    /assp_cfg.sh 'acceptAllMail:=' "acceptAllMail:=${ACCEPT_ALL_MAIL}" >> /custom.cfg && \
    /assp_cfg.sh 'DoLocalSenderDomain:=' "DoLocalSenderDomain:=1" >> /custom.cfg && \
    /assp_cfg.sh 'DoLocalSenderAddress:=' "DoLocalSenderAddress:=1" >> /custom.cfg && \
    /assp_cfg.sh 'relayHost:=' "relayHost:=${RELAY_HOST}" >> /custom.cfg && \
    /assp_cfg.sh 'relayPort:=' "relayPort:=${RELAY_PORT}" >> /custom.cfg && \
    /assp_cfg.sh 'allowRelayCon:=' "allowRelayCon:=${ALLOW_RELAY_CON}" >> /custom.cfg && \
    /assp_cfg.sh 'defaultLocalHost:=assp.local' "defaultLocalHost:=${DEFAULT_LOCALHOST}" >> /custom.cfg && \
    /assp_cfg.sh 'sendHamInbound:=' "sendHamInbound:=${SEND_HAM_INBOUND}" >> /custom.cfg && \
    /assp_cfg.sh 'sendHamOutbound:=' "sendHamOutbound:=${SEND_HAM_OUTBOUND}" >> /custom.cfg && \
    /assp_cfg.sh 'sendAllPostmaster:=' "sendAllPostmaster:=${POSTMASTER}" >> /custom.cfg && \
    /assp_cfg.sh 'LocalAddresses_Flat:=' "LocalAddresses_Flat:=file:files/localuser.txt" >> /custom.cfg && \
    /assp_cfg.sh 'localDomains:=putYourDomains.com' "here.org/localDomains:=${LOCAL_DOMAINS}" >> /custom.cfg && \
    /assp_cfg.sh 'myServerRe:=' "myServerRe:=${MY_SERVER_RE}" >> /custom.cfg && \
    /assp_cfg.sh 'noDelayAddresses:=' "noDelayAddresses:=${NO_DELAY}" >> /custom.cfg && \
    /assp_cfg.sh 'EmailAdminReportsTo:=' "EmailAdminReportsTo:=${MAILADMIN}" >> /custom.cfg && \
    /assp_cfg.sh 'EmailAdmins:=' "EmailAdmins:=${MAILADMIN}" >> /custom.cfg && \
    /assp_cfg.sh 'EmailFrom:=spammaster@yourdomain.com' "EmailFrom:=spammaster@assp.local" >> /custom.cfg && \
    /assp_cfg.sh 'sysLog:=' "sysLog:=1" >> /custom.cfg && \
    /assp_cfg.sh 'myName:=ASSP.nospam' "myName:=${MY_NAME}" >> /custom.cfg && \
    /assp_cfg.sh 'enableGraphStats:=0' "enableGraphStats:=1" >> /custom.cfg && \
    /assp_cfg.sh 'enableGraphStats:=0' "enableGraphStats:=1" >> /custom.cfg && \    
    cat /custom.cfg >> /assp-setdefaults.sh && \
    echo "kill -9 \`ps awwux | grep perl | grep assp | grep -v defaults | awk '{print \$1}'\`" >> /assp-setdefaults.sh && chmod a+x /assp-setdefaults.sh


# Create different supervisor entries
RUN /gen_sup.sh rsyslog "/usr/sbin/rsyslogd -n" >> /etc/supervisord.conf && \
    /gen_sup.sh mysqld "/start_mysqld.sh" >> /etc/supervisord.conf && \
    /gen_sup.sh clamd "/start_clamd.sh" >> /etc/supervisord.conf && \
    /gen_sup.sh crond "/start_crond.sh" >> /etc/supervisord.conf && \
    /gen_sup.sh postfix "/start_postfix.sh" >> /etc/supervisord.conf && \ 
    /gen_sup.sh opendkim "/start_opendkim.sh" >> /etc/supervisord.conf && \
    /gen_sup.sh assp "/start_assp.sh" >> /etc/supervisord.conf && \
    /gen_sup.sh assp-setdefaults "/assp-setdefaults.sh" >> /etc/supervisord.conf  

# Cleanup any cached files
RUN (rm -rf /root/.cpan/* 2>/dev/null || true) && (rm "/tmp/"* 2>/dev/null || true) && (rm -rf /var/cache/apk/* 2>/dev/null || true)

# Instantiate Volumes
VOLUME ["/etc/mysql","/var/lib/mysql","/var/log","/var/spool/postfix","/etc/opendkim","/usr/share/assp"]

# Running final script
ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
